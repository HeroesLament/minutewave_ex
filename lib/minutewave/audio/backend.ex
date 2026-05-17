defmodule Minutewave.Audio.Backend do
  @moduledoc """
  Behaviour for radio-side audio I/O.

  This is the audio path that carries modulated PCM between the protocol
  stack and the radio. On desktop, this is typically a Membrane pipeline
  over PortAudio against a USB sound card or DigiRig connected to the
  workstation. On mobile, this is Android's audio HAL routing PCM to a
  USB Audio Class device.

  Operator-facing audio (speaker, microphone, BT headset) is a *separate*
  concern handled by `Minutewave.OperatorVoice.Backend`. The radio-side
  backend is for modem audio only — including MELPe-encoded voice that
  travels as data inside 110D frames.

  ## Sample format

  Backends must accept and produce `i16` little-endian PCM samples. The
  sample rate is configured per backend at start-up; protocol code passes
  the rate it expects and the backend is responsible for resampling if
  the underlying device runs at a different rate.

  ## Per-rig multiplicity

  A single Elixir node may control multiple rigs simultaneously. Each
  rig is identified by an opaque `rig_id` (typically an atom or a UUID).
  Backends multiplex on `rig_id`; the protocol code does not know how
  many physical audio paths exist or how they are routed.
  """

  @typedoc """
  Opaque identifier for a rig. Each rig has its own audio backend instance.
  """
  @type rig_id :: term()

  @typedoc """
  Sample rate in Hz. Typically 9600 for 188-110D modem audio.
  """
  @type sample_rate :: pos_integer()

  @typedoc """
  Backend-specific options (device IDs, buffer sizes, etc.).
  """
  @type opts :: keyword()

  @typedoc """
  PCM sample data as a list of `i16` integers, or a binary of
  little-endian s16 samples. Backends should accept either form.
  """
  @type samples :: [integer()] | binary()

  @doc """
  Play a buffer of TX samples to the radio for the given rig.

  Returns `:ok` once the samples have been queued (not necessarily once
  they have completed playing — see `notify_tx_complete/1` for the
  completion signal).

  May return `{:error, reason}` if the backend is not ready, the device
  is disconnected, or the rig_id is not registered.
  """
  @callback play_tx(rig_id, samples, sample_rate, opts) ::
              :ok | {:error, term()}

  @doc """
  Start capturing RX samples from the radio for the given rig.

  Once started, the backend should send `{:rx_audio, rig_id, samples}`
  messages to the configured receiver process (typically the rig's
  RxFSM). Sample chunk size is backend-dependent but should be small
  enough to avoid stalling the demodulator.
  """
  @callback start_rx(rig_id, sample_rate) :: :ok | {:error, term()}

  @doc """
  Stop capturing RX samples for the given rig.
  """
  @callback stop_rx(rig_id) :: :ok

  @doc """
  Query whether TX is currently active for the given rig.

  Used by the Arbiter to determine whether a TX is in progress before
  granting a new TX acquisition.
  """
  @callback tx_active?(rig_id) :: boolean()

  @doc """
  Capabilities of this backend.

  Returns a map describing what the backend supports. Keys include:

    * `:simnet` (boolean) — whether this is a simulated network backend
    * `:half_duplex` (boolean) — true for radio-style half-duplex; false
      for full-duplex backends like simnet
    * `:sample_rates` (list of integer) — supported native sample rates
    * `:max_rigs` (integer or `:unlimited`) — maximum concurrent rigs
  """
  @callback capabilities() :: map()
end
