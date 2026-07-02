defmodule Minutewave.ALE.ACS do
  @moduledoc """
  Automatic Channel Selection (MIL-STD-188-141D G.5.4.1).

  The ACS function decides which channel a PU should use to call a given
  destination. Per G.5.4.1 the standard is deliberately non-prescriptive: it
  says ACS "should select channels in a fashion that optimizes overall network
  performance... using all available information as to propagation and occupancy
  of each channel and the requirements of the traffic." It names LQA data
  (Other Station Table), propagation prediction, and external measurements as
  valid inputs, but mandates no algorithm.

  This is the v1 policy layer: it ranks by empirical LQA and falls back to a
  configurable cold-start ordering when no LQA history exists. It is a thin
  process over pure pieces:

    * ranking math + Store access: `Minutewave.ALE.LQA` (unchanged)
    * current channel set: `Minutewave.RigState`
    * cold-start ordering: a named policy (see `t:cold_start/0`)

  Later factors (occupancy filtering per G.4.3.2, propagation prediction) slot
  in here without changing the query API.

  ## Query API

      ACS.rank(rig_id, dest_addr)  -> [%{freq_hz, score, basis, ...}, ...]  # best first
      ACS.best(rig_id, dest_addr)  -> %{freq_hz, basis} | {:error, :no_channels}

  `basis` is `:lqa` when the choice came from LQA history, or `:cold_start`
  when it came from the fallback ordering. This is deliberately surfaced so the
  UI and logs can show *why* a channel was chosen.

  ## Cold-start policy

  With no LQA history the order is decided by the `:cold_start` option:

    * `:config_order` (default) - the net's channel-list order, i.e. the order
      the operator/net planner supplied. This is the honest "no propagation
      knowledge yet" default; it respects operational intent rather than
      guessing.
    * `:highest_first` - highest frequency first (a daytime/DX propagation
      prior; wrong at night, NVIS, or solar minimum).
    * `:lowest_first` - lowest frequency first.

  When a propagation scorer is added it becomes the informed cold-start,
  superseding these orderings.

  ## Process model

  One ACS per rig, registered under `Minutewave.Rig.InstanceRegistry` as
  `{rig_id, :acs}`. It subscribes to the rig's `{:ale, {:lqa_observation, _}}`
  events so it can (later) maintain a cache and emit telemetry; v1 ranks
  on demand since `LQA.rank_channels/4` reads the Store directly and is cheap.
  """

  use GenServer
  require Logger

  alias Minutewave.ALE.LQA
  alias Minutewave.RigState
  alias Minutewave.Modem.Events

  @type cold_start :: :config_order | :highest_first | :lowest_first

  # ---- lifecycle ----

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :acs}}}
  end

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    cold_start = Keyword.get(opts, :cold_start, :config_order)

    # Subscribe to this rig's event bus for LQA observations. Best-effort:
    # the Events server may not be up yet in some test setups.
    try do
      Events.subscribe(rig_id, self(), filter: :rx)
    catch
      :exit, _ -> :ok
    end

    {:ok, %{rig_id: rig_id, cold_start: cold_start}}
  end

  # ---- public query API ----

  @doc """
  Rank the rig's current channels for calling `dest_addr`, best first. Each
  entry carries a `:basis` (`:lqa` | `:cold_start`). Returns `[]` if the rig has
  no channel set.
  """
  @spec rank(term(), integer(), keyword()) :: [map()]
  def rank(rig_id, dest_addr, opts \\ []) do
    GenServer.call(via(rig_id), {:rank, dest_addr, opts})
  end

  @doc """
  Best channel for calling `dest_addr`: `%{freq_hz, basis, ...}`, or
  `{:error, :no_channels}` if the rig has no channel set.
  """
  @spec best(term(), integer(), keyword()) :: map() | {:error, :no_channels}
  def best(rig_id, dest_addr, opts \\ []) do
    case rank(rig_id, dest_addr, opts) do
      [] -> {:error, :no_channels}
      [top | _] -> top
    end
  end

  # ---- server ----

  @impl true
  def handle_call({:rank, dest_addr, opts}, _from, state) do
    {:reply, do_rank(state, dest_addr, opts), state}
  end

  @impl true
  def handle_info({:ale, {:lqa_observation, _obs}}, state) do
    # v1: observations are persisted by the Store consumer and read on demand
    # by LQA.rank_channels. We subscribe now so the cache/telemetry hooks have
    # a home later; nothing to accumulate here yet.
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---- ranking + cold-start ----

  defp do_rank(state, dest_addr, opts) do
    channels = RigState.field(state.rig_id, :channels, []) || []

    case channels do
      [] ->
        []

      _ ->
        ranked = LQA.rank_channels(state.rig_id, dest_addr, channels, opts)

        if lqa_usable?(ranked) do
          Enum.map(ranked, &Map.put(&1, :basis, :lqa))
        else
          cold_start_order(channels, state.cold_start)
        end
    end
  end

  # LQA is usable if at least one channel has a positive score (real history).
  defp lqa_usable?(ranked), do: Enum.any?(ranked, &(&1.score > 0))

  defp cold_start_order(channels, policy) do
    freqs = Enum.map(channels, &freq_of/1)

    ordered =
      case policy do
        :highest_first -> Enum.sort(freqs, :desc)
        :lowest_first -> Enum.sort(freqs, :asc)
        :config_order -> freqs
      end

    Enum.map(ordered, fn freq ->
      %{freq_hz: freq, score: 0.0, last_heard: nil, count: 0, basis: :cold_start}
    end)
  end

  defp freq_of(ch), do: ch.freq_hz || ch[:freq_hz] || ch["freq_hz"]
end
