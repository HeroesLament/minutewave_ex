defmodule Minutewave.Clock.Source do
  @moduledoc """
  Behaviour for **pull-shaped** physical-time discipline sources feeding
  `Minutewave.Clock`.

  The library defines the *interface*; concrete implementations (a serial NMEA
  USB receiver on a fixed station, a test stub, etc.) live in the integrating
  application. This mirrors how `Minutewave.Rig.Control.Behaviour` defines the
  rig interface while concrete rigs are supplied by integrators. minutewave_ex
  never imports a platform API — not Android, not a serial library — it only
  defines this contract and ingests the resulting fixes.

  ## Pull vs. push sources

  There are two shapes of GNSS/time source, and they reach the clock
  differently. Both keep platform code out of the library.

    * **Pull sources** (USB GPS, serial NMEA, test stub): you poll them. They
      implement this behaviour — `read_fix/0` returns the latest fix on demand.
      `Minutewave.Clock.Poller` drives them: it calls `read_fix/0` on a cadence
      and forwards each `{:ok, fix}` to `Minutewave.Clock.discipline_gnss/1`.
      The integrator just starts a Poller with the source module.

    * **Push sources** (e.g. Android `GnssMeasurementsCallback`): the platform
      calls *you* when a measurement arrives. These do **not** implement this
      behaviour and do **not** need a Poller. The integrator's callback simply
      calls `Minutewave.Clock.discipline_gnss/1` directly each time a fix
      arrives. `discipline_gnss/1` is the universal ingestion point for both
      shapes; the behaviour + Poller are a convenience for the pull case only.

  ## Building a fix

  Whichever shape, a fix is the triple the clock needs to model time, NOT just
  a wall-clock reading:

    1. true time from the source (e.g. GNSS UTC), as `:protocol_time_ms`;
    2. the monotonic instant that time was captured (`:mono_ms`), so the clock
       can hold an offset that survives wall-clock jumps;
    3. the measured error bound (`:uncertainty_ms`), which drives holdover
       growth and stratum arbitration.

  On Android specifically, this means reading `GnssClock` (bias + time
  uncertainty) from the raw measurements API, not `System.currentTimeMillis/0`
  — the system clock is NITZ/NTP-disciplined and discards the GNSS receiver's
  precision. A pull source over USB NMEA reads `$GPZDA`/`$GPRMC` time and pairs
  it with `System.monotonic_time(:millisecond)` captured at sentence arrival.

  ## Stratum

  Each fix advertises a `:stratum` (0 = direct physical reference such as GNSS;
  higher = derived). The clock only ever disciplines *up* the quality gradient
  (toward lower stratum / lower uncertainty), never sideways or down — the same
  hygiene NTP uses to avoid runaway, and what makes accepting a peer's time
  (TOD) safe.
  """

  @typedoc """
  A disciplined time observation.

    * `:protocol_time_ms` - the source's best estimate of true time, in
      milliseconds since the Unix epoch, *as of* the instant captured in
      `:mono_ms`.
    * `:mono_ms` - the local `System.monotonic_time(:millisecond)` reading
      captured as close as possible to the same instant `:protocol_time_ms`
      refers to. The pairing of these two is what lets the clock compute and
      track an offset that survives wall-clock jumps.
    * `:uncertainty_ms` - half-width of the error bound on `:protocol_time_ms`
      (a "this time is correct to within ± uncertainty" figure). GNSS fixes are
      typically sub-millisecond; a peer TOD response carries the peer's own
      uncertainty plus the path-delay estimate.
    * `:stratum` - distance from a true physical reference. 0 for GNSS.
  """
  @type fix :: %{
          protocol_time_ms: integer(),
          mono_ms: integer(),
          uncertainty_ms: non_neg_integer(),
          stratum: non_neg_integer()
        }

  @doc """
  Return the source's current fix, or `:no_fix` if no valid time is available
  right now (e.g. GNSS has no sky view). Must not block for long; the Poller
  calls this on a cadence.
  """
  @callback read_fix() :: {:ok, fix()} | :no_fix

  @doc "Human-readable source name, for logging/telemetry (e.g. \"usb-nmea\")."
  @callback name() :: String.t()

  @doc """
  The source's natural fix cadence in milliseconds. The Poller uses this as its
  default poll interval so a slow receiver (e.g. 1 Hz NMEA) isn't hammered and
  a faster one isn't undersampled. Optional; the Poller falls back to its own
  default if not implemented.
  """
  @callback suggested_interval_ms() :: pos_integer()

  @optional_callbacks suggested_interval_ms: 0
end
