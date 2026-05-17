defmodule Minutewave.Rig.Control do
  @moduledoc """
  Behaviour for radio control (CAT — Computer-Aided Transceiver).

  Frequency, mode, and PTT are the three universal operations every HF
  radio supports. Implementations vary widely: Hamlib/rigctld for desktop
  users with conventional rigs, flrig for users running fldigi, direct
  CAT protocol over USB serial (Yaesu / Icom / Kenwood specific) for
  mobile deployments, and simulators for testing.

  The behaviour is intentionally minimal at this layer — protocol code
  needs to acquire TX exclusively, set frequency, query state, and
  release. Higher-order operations (memory channels, antenna tuner,
  filter selection) belong in radio-specific extensions.

  ## Per-rig instances

  Each rig gets its own `Rig.Control` process, registered via
  `Minutewave.Rig.InstanceRegistry`. The `rig_id` identifies which
  process to talk to.

  ## TX arbitration

  Protocol code (data, voice, ALE) competes for TX access via
  `acquire_tx/2` with a usage tag. The backend grants exclusive access
  to one tag at a time; subsequent callers receive `{:error, :busy}`
  with the current owner tag. This is the lock; the actual audio
  routing decision is made downstream by the Arbiter once TX is held.
  """

  @typedoc """
  Opaque rig identifier.
  """
  @type rig_id :: term()

  @typedoc """
  Frequency in Hz.
  """
  @type frequency :: pos_integer()

  @typedoc """
  Radio operating mode.

  Note: when running MELPe-over-110D voice, the radio mode is still
  a data mode (typically `:usb` or `:lsb` with the modem coupled
  through DigiRig); the operator's voice never goes to the radio as
  analog audio. The `:fm` / `:am` / `:cw` modes are included for
  completeness when minutewave is used as a general-purpose rig
  control layer.
  """
  @type mode :: :usb | :lsb | :am | :fm | :cw | :digital

  @typedoc """
  TX usage tag. Identifies *what* is transmitting so the Arbiter
  can route the right audio source to the radio.

    * `:data` — modem data frames
    * `:voice` — MELPe-encoded voice (carried as data inside 110D)
    * `:ale` — ALE link establishment
    * `:tune` — antenna tuner cycle (no protocol data; just a carrier)
  """
  @type tx_tag :: :data | :voice | :ale | :tune

  @doc """
  Acquire exclusive TX access for the given usage.

  Returns `:ok` if acquired, or `{:error, {:busy, current_tag}}` if
  another caller currently holds TX.
  """
  @callback acquire_tx(rig_id, tx_tag) ::
              :ok | {:error, {:busy, tx_tag}} | {:error, term()}

  @doc """
  Release TX access. Idempotent; calling release when not holding TX
  is a no-op.
  """
  @callback release_tx(rig_id) :: :ok

  @doc """
  Get the current operating frequency in Hz.
  """
  @callback get_frequency(rig_id) :: {:ok, frequency} | {:error, term()}

  @doc """
  Set the operating frequency in Hz.
  """
  @callback set_frequency(rig_id, frequency) :: :ok | {:error, term()}

  @doc """
  Get the current operating mode.
  """
  @callback get_mode(rig_id) :: {:ok, mode} | {:error, term()}

  @doc """
  Set the operating mode.
  """
  @callback set_mode(rig_id, mode) :: :ok | {:error, term()}

  @doc """
  Query the overall rig status: frequency, mode, TX state, signal
  level (if the backend can report it). Used for UI status displays.

  Returns a map with at least `:frequency`, `:mode`, and `:tx_active?`
  keys. May contain additional backend-specific keys.
  """
  @callback status(rig_id) :: {:ok, map()} | {:error, term()}

  @doc """
  Capabilities of this backend.

  Returns a map describing what the backend supports. Keys include:

    * `:simulator` (boolean)
    * `:reports_signal_level` (boolean) — whether `status/1` includes `:s_meter`
    * `:vfo_count` (integer) — typically 1, 2 for radios with VFO-A/B
    * `:supported_modes` (list of mode atoms)
  """
  @callback capabilities() :: map()
end
