defmodule Minutewave.Audio.Backend do
  @moduledoc """
  Behaviour for radio-side audio I/O.

  This is the audio path that carries modulated PCM between the protocol
  stack and the radio. On desktop, this is typically a Membrane pipeline
  over PortAudio against a USB sound card or DigiRig connected to the
  workstation. On mobile, this is Android's audio HAL routing PCM to a
  USB Audio Class device.

  Operator-facing audio (speaker, microphone, BT headset) is a *separate*
  concern that minutewave does not model. The radio-side backend is for
  modem audio only — including MELPe-encoded voice that travels as data
  inside 110D frames.

  ## Sample format

  Backends produce `i16` PCM samples. The sample rate is backend-defined;
  protocol code receives whatever the backend sends and is responsible for
  matching its DSP configuration to the backend's native rate.

  ## RX delivery model

  RX is pub/sub. The protocol code (typically RxFSM) calls `subscribe/1`
  during initialization. The backend sends RX audio to subscribers as
  Erlang messages of one of two shapes:

      {:rx_audio, rig_id, samples}
      {:rx_audio, rig_id, samples, metadata}

  The second form carries backend-specific metadata (e.g. simnet channel
  state, SNR estimates). Subscribers should pattern-match both.

  ## TX delivery model

  TX is push. The protocol code calls `play_tx/4` with a buffer of samples;
  the backend queues them for transmission. `tx_active?/1` lets the Arbiter
  check whether a TX is currently in flight before granting a new one.

  ## Per-rig multiplicity

  A single Elixir node may control multiple rigs simultaneously. Each
  rig is identified by an opaque `rig_id`. Backends multiplex on `rig_id`;
  protocol code does not know how many physical audio paths exist or how
  they are routed.
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
  Subscribe the calling process to RX audio for the given rig.

  After subscribing, the caller receives messages of shape
  `{:rx_audio, rig_id, samples}` or `{:rx_audio, rig_id, samples, metadata}`.
  """
  @callback subscribe(rig_id) :: :ok | {:error, term()}

  @doc """
  Unsubscribe the calling process from RX audio for the given rig.
  """
  @callback unsubscribe(rig_id) :: :ok

  @doc """
  Play a buffer of TX samples to the radio for the given rig.

  Returns `:ok` once the samples have been queued (not necessarily once
  they have completed playing).

  May return `{:error, reason}` if the backend is not ready, the device
  is disconnected, or the rig_id is not registered.
  """
  @callback play_tx(rig_id, samples, sample_rate, opts) ::
              :ok | {:error, term()}

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
