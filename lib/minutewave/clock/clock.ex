defmodule Minutewave.Clock do
  @moduledoc """
  Disciplined virtual clock for synchronous ALE scanning.

  ## Why this exists

  Synchronous 4G ALE scanning (and 3G-style trunked operation) requires all
  stations on a net to agree on absolute time well enough that their scan
  dwells land in lockstep. The ALE link FSM previously read
  `System.os_time/1` directly for its sync epoch, which trusts the phone's
  wall clock (NITZ/NTP) — fine on a desk, unreliable in the field, and
  impossible to steer from userspace on unrooted Android.

  This server owns an app-private **virtual clock**: an offset/rate model
  layered over `System.monotonic_time/1` (which never jumps and is unaffected
  by NITZ/NTP/user changes). Protocol time is computed as

      protocol_time_ms = mono_now_ms * rate + offset_ms

  and every consumer that needs "what time is it for sync purposes" reads
  `protocol_time_ms/0` here instead of touching the OS wall clock. We never
  call `clock_settime` / touch `CLOCK_REALTIME` — that's privileged and would
  perturb the whole phone. We discipline *our own* model only.

  ## Sources and arbitration

  Discipline inputs arrive as `t:Minutewave.Clock.Source.fix/0` values:

    * **GNSS** (`discipline_gnss/1`) — the default, automatic source. When a
      fix is present the clock disciplines to it unconditionally; GNSS is the
      best reference we have (stratum 0, sub-ms uncertainty).
    * **TOD** (`discipline_tod/1`) — peer-sourced time from a remote station's
      Time-of-Day response. This is **opt-in** (`set_tod_admissible/1`) and is
      only accepted when (a) the operator has enabled it and (b) the peer's
      effective quality beats our current quality — i.e. we only sync *up* the
      stratum/uncertainty gradient. This is the guard against a malicious or
      mis-disciplined peer dragging us off time (desync DoS).

  ## Holdover and degradation

  Between fixes the clock free-runs on the monotonic base. Its `uncertainty_ms`
  **grows** with elapsed holdover time (a configurable drift rate, since a
  phone TCXO is mediocre). Consumers use `quality/0` to decide whether they may
  remain in synchronous operation:

    * `:locked`   — recently disciplined, uncertainty within guard.
    * `:holdover` — coasting, uncertainty still within guard.
    * `:unsynced` — uncertainty has exceeded the guard band, or we have never
      been disciplined. Synchronous scanning must degrade to async / shared
      pool when this is reported.

  The guard band is the slot/dwell tolerance: as long as accumulated
  uncertainty stays under it, lockstep scanning is still valid.
  """

  use GenServer
  require Logger

  alias Minutewave.Clock.Source

  @name __MODULE__

  # Assumed free-running fractional frequency error of the local oscillator
  # during holdover, expressed as ms of uncertainty growth per ms elapsed.
  # 2.0e-5 ≈ 20 ppm, a conservative figure for a consumer phone TCXO. Override
  # via start_link opts once you've characterised real drift empirically.
  @default_drift_ppm 20

  # Uncertainty (ms) at or beyond which we declare :unsynced and consumers must
  # leave synchronous operation. Should be set from the net's slot guard time.
  @default_guard_ms 250

  # A fix older than this (ms, monotonic) is treated as no longer authoritative
  # for "locked": we transition locked -> holdover.
  @default_lock_ttl_ms 5_000

  defstruct offset_ms: 0,
            rate: 1.0,
            # uncertainty + mono timestamp at the moment of last discipline
            base_uncertainty_ms: nil,
            disciplined_mono_ms: nil,
            stratum: nil,
            source_name: nil,
            tod_admissible: false,
            drift_ms_per_ms: @default_drift_ppm / 1_000_000,
            guard_ms: @default_guard_ms,
            lock_ttl_ms: @default_lock_ttl_ms

  @type quality :: :locked | :holdover | :unsynced

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Current protocol time in milliseconds since the Unix epoch, per the
  disciplined virtual clock. This is what sync-scan epoch math must use in
  place of `System.os_time/1`.

  Always returns a value: if the clock has never been disciplined it falls
  back to `System.os_time/1` so behaviour degrades to "trust the OS clock"
  rather than failing — but `quality/0` will report `:unsynced` in that case,
  so synchronous consumers know not to rely on it.
  """
  @spec protocol_time_ms() :: integer()
  def protocol_time_ms(server \\ @name) do
    GenServer.call(server, :protocol_time_ms)
  end

  @doc """
  Current clock quality (`:locked | :holdover | :unsynced`) and the estimated
  uncertainty half-width in ms. Consumers gate synchronous operation on this.
  """
  @spec quality() :: {quality(), non_neg_integer()}
  def quality(server \\ @name) do
    GenServer.call(server, :quality)
  end

  @doc """
  Feed a GNSS (or other stratum-0 physical) fix. Always accepted — GNSS is the
  default authoritative source.
  """
  @spec discipline_gnss(Source.fix()) :: :ok
  def discipline_gnss(fix, server \\ @name) do
    GenServer.cast(server, {:discipline, :gnss, fix})
  end

  @doc """
  Offer a peer-sourced Time-of-Day fix. Accepted only if TOD is admissible
  (opt-in) **and** the offered fix improves on our current quality (synced up
  the gradient). Otherwise silently ignored. Returns `:ok` regardless; inspect
  `quality/0` to see whether it took effect.
  """
  @spec discipline_tod(Source.fix()) :: :ok
  def discipline_tod(fix, server \\ @name) do
    GenServer.cast(server, {:discipline, :tod, fix})
  end

  @doc "Enable/disable acceptance of peer TOD time. Off by default."
  @spec set_tod_admissible(boolean()) :: :ok
  def set_tod_admissible(bool, server \\ @name) when is_boolean(bool) do
    GenServer.cast(server, {:set_tod_admissible, bool})
  end

  @doc """
  Build a `t:Minutewave.Clock.Source.fix/0` describing *our own* current time,
  for serving to a peer that requested TOD. Carries our present uncertainty and
  a stratum one greater than our own source (we are downstream of whatever
  disciplines us). Returns `:no_fix` if we are `:unsynced` (we won't serve time
  we don't trust).
  """
  @spec serve_fix() :: {:ok, Source.fix()} | :no_fix
  def serve_fix(server \\ @name) do
    GenServer.call(server, :serve_fix)
  end

  # -------------------------------------------------------------------
  # Server
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      tod_admissible: Keyword.get(opts, :tod_admissible, false),
      drift_ms_per_ms: Keyword.get(opts, :drift_ppm, @default_drift_ppm) / 1_000_000,
      guard_ms: Keyword.get(opts, :guard_ms, @default_guard_ms),
      lock_ttl_ms: Keyword.get(opts, :lock_ttl_ms, @default_lock_ttl_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:protocol_time_ms, _from, state) do
    {:reply, now_protocol_ms(state, mono_ms()), state}
  end

  def handle_call(:quality, _from, state) do
    mono = mono_ms()
    {:reply, {quality(state, mono), round_unc(current_uncertainty(state, mono))}, state}
  end

  def handle_call(:serve_fix, _from, state) do
    mono = mono_ms()

    reply =
      case quality(state, mono) do
        :unsynced ->
          :no_fix

        _ ->
          {:ok,
           %{
             protocol_time_ms: now_protocol_ms(state, mono),
             mono_ms: mono,
             uncertainty_ms: round(current_uncertainty(state, mono)),
             # we are one hop further from the physical reference than our source
             stratum: (state.stratum || 0) + 1
           }}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:set_tod_admissible, bool}, state) do
    Logger.info("Clock: TOD peer-sync #{if bool, do: "ENABLED", else: "disabled"}")
    {:noreply, %{state | tod_admissible: bool}}
  end

  def handle_cast({:discipline, :gnss, fix}, state) do
    # GNSS is the default reference: always accept.
    {:noreply, apply_fix(state, fix, "gnss")}
  end

  def handle_cast({:discipline, :tod, fix}, state) do
    mono = mono_ms()

    cond do
      not state.tod_admissible ->
        # Opt-in gate: peer time is not admissible.
        {:noreply, state}

      not improves?(state, fix, mono) ->
        # Only sync up the gradient. Refuse sideways/downward syncs.
        Logger.debug("Clock: rejected TOD fix (no quality improvement)")
        {:noreply, state}

      true ->
        Logger.info(
          "Clock: accepted TOD peer time (stratum #{fix.stratum}, ±#{fix.uncertainty_ms}ms)"
        )

        {:noreply, apply_fix(state, fix, "tod")}
    end
  end

  # -------------------------------------------------------------------
  # Discipline math
  # -------------------------------------------------------------------

  # Apply a fix by computing the offset that makes our virtual clock read the
  # fix's protocol time at the fix's mono instant. We discipline offset only
  # (single-shot); rate stays 1.0. A future enhancement can estimate rate from
  # successive fixes to improve holdover, but offset discipline is correct and
  # sufficient for dwell-scale alignment.
  defp apply_fix(state, fix, source_name) do
    # offset such that: fix.protocol_time_ms == fix.mono_ms * rate + offset
    offset = fix.protocol_time_ms - round(fix.mono_ms * state.rate)

    %{
      state
      | offset_ms: offset,
        base_uncertainty_ms: fix.uncertainty_ms,
        disciplined_mono_ms: fix.mono_ms,
        stratum: fix.stratum,
        source_name: source_name
    }
  end

  # Does this fix improve on our current state? Compare effective uncertainty:
  # the peer's uncertainty *as it will be for us* vs our current (grown)
  # uncertainty. Lower stratum is preferred, then lower uncertainty.
  defp improves?(%{base_uncertainty_ms: nil}, _fix, _mono), do: true

  defp improves?(state, fix, mono) do
    ours = current_uncertainty(state, mono)
    # A peer at stratum S serves us at S+1; its fix already reflects path delay
    # in uncertainty_ms (the caller's responsibility to fold in). Prefer it if
    # it leaves us better off than our coasted uncertainty.
    fix.uncertainty_ms < ours
  end

  # Protocol time = mono * rate + offset. Before first discipline, fall back to
  # OS wall clock so the system still functions (degraded, :unsynced).
  defp now_protocol_ms(%{disciplined_mono_ms: nil}, _mono), do: System.os_time(:millisecond)
  defp now_protocol_ms(state, mono), do: round(mono * state.rate) + state.offset_ms

  # Uncertainty grows linearly with holdover since last discipline.
  defp current_uncertainty(%{base_uncertainty_ms: nil}, _mono), do: :infinity

  defp current_uncertainty(state, mono) do
    elapsed = max(mono - state.disciplined_mono_ms, 0)
    state.base_uncertainty_ms + elapsed * state.drift_ms_per_ms
  end

  defp quality(%{disciplined_mono_ms: nil}, _mono), do: :unsynced

  defp quality(state, mono) do
    unc = current_uncertainty(state, mono)
    age = mono - state.disciplined_mono_ms

    cond do
      unc >= state.guard_ms -> :unsynced
      age <= state.lock_ttl_ms -> :locked
      true -> :holdover
    end
  end

  defp round_unc(:infinity), do: :infinity
  defp round_unc(n), do: round(n)

  defp mono_ms, do: System.monotonic_time(:millisecond)
end
