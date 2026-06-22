defmodule Minutewave.ALE.LQA do
  @moduledoc """
  Link Quality Analysis engine (storage-agnostic).

  Computes channel-quality scores from decoded ALE frame metrics and ranks
  candidate channels for automatic frequency selection. This module owns the
  scoring math and the ranking math; it does **not** own persistence.

  ## Two seams to the consumer

  1. **Observations out (events).** Each successfully decoded PDU is an LQA
     observation. `record_observation/5` scores the metrics and broadcasts
     `{:ale, {:lqa_observation, map}}` via `Minutewave.Modem.Events`. The
     consumer subscribes and persists however it likes. This mirrors the
     `{:ale, {:sounding_made, _}}` seam used by `Minutewave.ALE.LQA.Sounder`.

  2. **History in (store behaviour).** Ranking needs past observations, which
     this library does not store. `rank_channels/4` and `best_channel/3` fetch
     them through a configured store implementing `Minutewave.ALE.LQA.Store`,
     then apply time-decayed scoring here. Configure with:

         config :minutewave, lqa_store: MyApp.ALE.LqaStore

     Same pattern as `Minutewave.Rig.Control` and `Minutewave.Audio`.

  ## Scoring

  Composite score (0-100) from decode metrics:

  - **Probe correlation** (0-30 pts) - IQ consistency / signal detection.
    Below 40 = 0 (noise floor); linear 40..90.
  - **Path metric delta** (0-40 pts) - Viterbi decode confidence.
    Linear 0..16 (LLR clamp at +/-4.0 caps the real range).
  - **Average LLR magnitude** (0-30 pts) - soft-decision reliability.
    Linear with saturation at |LLR| = 4.0.

  Calibrated against the LQAChannelTest Watterson sweep (2026-02-21):
    AWGN +10 dB -> ~90, Good 0 dB -> ~70, Poor +2 dB -> ~55,
    Poor -5 dB -> ~35, Failed decode -> 0.
  """

  alias Minutewave.ALE.PDU
  alias Minutewave.Modem.Events

  require Logger

  # -------------------------------------------------------------------
  # Scoring (pure)
  # -------------------------------------------------------------------

  @doc """
  Compute a composite LQA score (0-100) from decode metrics.

  Accepts a map with any subset of `:probe_corr`, `:path_metric_delta`,
  `:avg_llr`. Missing metrics contribute 0 to their component.
  """
  def score(metrics) when is_map(metrics) do
    probe = score_probe(Map.get(metrics, :probe_corr, 0))
    viterbi = score_viterbi(Map.get(metrics, :path_metric_delta, 0.0))
    llr = score_llr(Map.get(metrics, :avg_llr, 0.0))

    Float.round(probe + viterbi + llr, 1)
  end

  defp score_probe(corr) when is_number(corr) do
    clamped = max(0.0, min(100.0, corr))
    if clamped < 40.0, do: 0.0, else: (clamped - 40.0) / 50.0 * 30.0
  end

  defp score_viterbi(delta) when is_number(delta) do
    clamped = max(0.0, min(16.0, delta))
    clamped / 16.0 * 40.0
  end

  defp score_llr(avg) when is_number(avg) do
    clamped = max(0.0, min(4.0, avg))
    clamped / 4.0 * 30.0
  end

  # -------------------------------------------------------------------
  # Recording (event-emitting; no persistence)
  # -------------------------------------------------------------------

  @doc """
  Score a decoded-frame observation and broadcast it for the consumer to persist.

  Emits `{:ale, {:lqa_observation, map}}` on the rig's event bus. The map
  carries the computed `:score` plus the raw inputs so a subscriber can both
  store the score and recompute if scoring weights change later.

  ## Parameters
    * `rig_id` - the rig that received the frame
    * `source_addr` - the remote station's ALE address (from the PDU)
    * `freq_hz` - frequency the frame was received on
    * `metrics` - decode quality metrics map
    * `opts` - `:frame_type` (default `"call"`), `:net_id`, `:snr_db`
  """
  def record_observation(rig_id, source_addr, freq_hz, metrics, opts \\ []) do
    lqa_score = score(metrics)

    Events.broadcast(rig_id, {:ale, {:lqa_observation, %{
      rig_id: rig_id,
      source_addr: source_addr,
      freq_hz: freq_hz,
      score: lqa_score,
      direction: :rx,
      frame_type: Keyword.get(opts, :frame_type, "call"),
      net_id: Keyword.get(opts, :net_id),
      snr_db: Keyword.get(opts, :snr_db),
      metrics: %{
        probe_corr: Map.get(metrics, :probe_corr),
        path_metric_delta: Map.get(metrics, :path_metric_delta),
        path_metric: Map.get(metrics, :path_metric),
        avg_llr: Map.get(metrics, :avg_llr),
        min_llr: Map.get(metrics, :min_llr),
        preamble_zeros: Map.get(metrics, :preamble_zeros),
        waveform: Map.get(metrics, :waveform) |> to_string_or_nil(),
        decode_path: Map.get(metrics, :decode_path) |> to_string_or_nil()
      }
    }}})

    lqa_score
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(val), do: to_string(val)

  # -------------------------------------------------------------------
  # Channel ranking (library math over store-supplied observations)
  # -------------------------------------------------------------------

  @doc """
  Rank candidate channels by LQA quality for a destination station.

  Fetches recent observations for `dest_addr` from the configured
  `Minutewave.ALE.LQA.Store`, applies exponential time decay (recent
  observations dominate), and returns channels sorted best-first. Channels
  with no observations sort last with score 0.

  ## Options
    * `:hours` - lookback window (default 24)
    * `:decay_hours` - half-life for time decay (default 4)

  ## Returns
      [%{freq_hz: integer, score: float, last_heard: DateTime.t() | nil, count: integer}, ...]
  """
  def rank_channels(rig_id, dest_addr, channels, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    decay_hours = Keyword.get(opts, :decay_hours, 4)
    freq_list = Enum.map(channels, &freq_of/1)

    observations = store().recent_observations(rig_id, dest_addr, freq_list, hours: hours)
    now = DateTime.utc_now()
    by_freq = Enum.group_by(observations, & &1.freq_hz)

    freq_list
    |> Enum.map(fn freq ->
      case Map.get(by_freq, freq, []) do
        [] ->
          %{freq_hz: freq, score: 0.0, last_heard: nil, count: 0}

        obs ->
          {weighted_sum, weight_total} =
            Enum.reduce(obs, {0.0, 0.0}, fn o, {ws, wt} ->
              age_hours = DateTime.diff(now, o.timestamp, :second) / 3600.0
              weight = :math.exp(-0.693 * age_hours / decay_hours)
              {ws + (o.score || 0.0) * weight, wt + weight}
            end)

          avg = if weight_total > 0, do: weighted_sum / weight_total, else: 0.0
          last = obs |> Enum.map(& &1.timestamp) |> Enum.max(DateTime)
          %{freq_hz: freq, score: Float.round(avg, 1), last_heard: last, count: length(obs)}
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  Return the best channel for a destination, or nil if no LQA data exists.
  """
  def best_channel(rig_id, dest_addr, channels, opts \\ []) do
    case rank_channels(rig_id, dest_addr, channels, opts) do
      [%{score: score} = best | _] when score > 0 -> best
      _ -> nil
    end
  end

  @doc """
  Return the channel most in need of a sounding (oldest or no data).

  Returns `%{freq_hz: integer, last_heard: DateTime.t() | nil}`.
  """
  def stalest_channel(rig_id, channels, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    freq_list = Enum.map(channels, &freq_of/1)
    recent = store().last_heard_per_freq(rig_id, freq_list, hours: hours)

    freq_list
    |> Enum.map(fn freq -> %{freq_hz: freq, last_heard: Map.get(recent, freq)} end)
    |> Enum.sort_by(fn
      %{last_heard: nil} -> DateTime.from_unix!(0)
      %{last_heard: ts} -> ts
    end, DateTime)
    |> List.first()
  end

  defp freq_of(ch), do: ch.freq_hz || ch[:freq_hz] || ch["freq_hz"]

  defp store do
    Application.get_env(:minutewave, :lqa_store) ||
      raise """
      Minutewave.ALE.LQA: no lqa_store configured. Set:

          config :minutewave, lqa_store: MyApp.ALE.LqaStore

      implementing the Minutewave.ALE.LQA.Store behaviour.
      """
  end

  # -------------------------------------------------------------------
  # PDU helpers (pure)
  # -------------------------------------------------------------------

  @doc "Extract the remote station's ALE address from a decoded PDU, or nil."
  def source_addr(%{caller_addr: addr}) when is_integer(addr), do: addr
  def source_addr(%{called_addr: addr}) when is_integer(addr), do: addr
  def source_addr(_), do: nil

  @doc "Map a decoded PDU to its LQA frame_type string."
  def frame_type(%PDU.LsuReq{}), do: "call"
  def frame_type(%PDU.LsuConf{}), do: "response"
  def frame_type(%PDU.LsuTerm{}), do: "terminate"
  def frame_type(%PDU.LsuStatus{}), do: "sounding"
  def frame_type(_), do: "data"
end
