defmodule Minutewave.ALE.Transmitter do
  @moduledoc """
  Bridges the ALE Link state machine to the audio output.

  Takes symbol streams from the Link FSM, modulates them via the
  PHY modem NIF, and pushes audio samples to the rig's audio pipeline.

  Routes audio through Modem.Events so Rig.AudioPipeline can decide
  where to send it (speakers for physical rigs, simnet for test rigs).

  Each rig has one Transmitter instance.
  """

  use GenServer

  require Logger

  alias Minutewave.Dsp.PhyModem
  alias Minutewave.Modem.Events
  alias Minutewave.Rig.Control
  alias Minutewave.Audio

  @default_sample_rate 9600

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :ale_tx}}}
  end

  @doc """
  Transmit a list of symbols.

  Modulates the symbols and sends audio to the rig's TX pipeline.
  Returns when transmission is complete.
  """
  @spec transmit(term(), [0..7]) :: :ok | {:error, term()}
  def transmit(rig_id, symbols) when is_list(symbols) do
    GenServer.call(via(rig_id), {:transmit, symbols}, :infinity)
  end

  @doc """
  Get the current transmitter state.
  """
  @spec get_state(term()) :: :idle | :transmitting
  def get_state(rig_id) do
    GenServer.call(via(rig_id), :get_state)
  end

  # -------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)

    Logger.info("ALE Transmitter starting for rig #{rig_id} @ #{sample_rate}Hz")

    modulator = PhyModem.unified_mod_new(:psk8, sample_rate)

    state = %{
      rig_id: rig_id,
      sample_rate: sample_rate,
      modulator: modulator,
      tx_state: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:transmit, symbols}, _from, state) do
    Logger.debug("ALE TX [#{state.rig_id}] transmitting #{length(symbols)} symbols")

    case Control.acquire_tx(state.rig_id, :ale) do
      :ok ->
        result = do_transmit(symbols, state)
        Control.release_tx(state.rig_id, :ale)
        {:reply, result, state}

      {:error, :busy} ->
        Logger.warning("ALE TX [#{state.rig_id}] rig TX busy, cannot transmit")
        {:reply, {:error, :tx_busy}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.tx_state, state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp do_transmit(symbols, state) do
    # Zero-copy modulate: symbols in, s16le PCM binary out (no per-sample lists).
    body = PhyModem.unified_mod_modulate_bin(state.modulator, symbols)
    tail = PhyModem.unified_mod_flush_bin(state.modulator)
    binary = body <> tail

    PhyModem.unified_mod_reset(state.modulator)

    sample_count = div(byte_size(binary), 2)
    duration_ms = sample_count / state.sample_rate * 1000
    Logger.info("ALE TX [#{state.rig_id}] #{length(symbols)} symbols -> #{sample_count} samples (#{round(duration_ms)}ms)")

    result = send_to_audio_pipeline(state.rig_id, binary, state.sample_rate)

    broadcast_tx_event(state.rig_id, length(symbols), sample_count, duration_ms)

    result
  rescue
    e ->
      Logger.error("ALE TX [#{state.rig_id}] transmit failed: #{inspect(e)}")
      {:error, e}
  end

  defp send_to_audio_pipeline(rig_id, binary, sample_rate) when is_binary(binary) do
    # Push to the configured audio backend (the producer->hardware link). On
    # mobile this is the USB PCM backend, which enqueues to the DigiRig
    # AudioTrack and keys/holds PTT for the duration via the Manager.
    Minutewave.Audio.play_tx(rig_id, binary, sample_rate, [])

    # Also emit the legacy events/pg broadcasts for UI/telemetry/loopback.
    Events.broadcast(rig_id, {:modem, {:tx_audio, binary}})
    Logger.debug("ALE TX [#{rig_id}] sent #{byte_size(binary)} bytes to audio backend")
    broadcast(rig_id, {:tx_audio, rig_id, binary, sample_rate})

    if Application.get_env(:minutemodem_core, :debug_tx_audio, false) do
      write_debug_wav(rig_id, binary, sample_rate)
    end

    :ok
  rescue
    e ->
      Logger.error("ALE TX [#{rig_id}] failed to send audio: #{inspect(e)}")
      {:error, e}
  end

  defp write_debug_wav(rig_id, binary, sample_rate) do
    byte_rate = sample_rate * 2
    size = byte_size(binary)

    wav_header = <<
      "RIFF",
      (size + 36)::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      1::little-16,
      1::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      2::little-16,
      16::little-16,
      "data",
      size::little-32
    >>

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = "/tmp/ale_tx_#{rig_id}_#{timestamp}.wav"
    File.write!(filename, wav_header <> binary)
    Logger.debug("ALE TX [#{rig_id}] wrote debug WAV: #{filename}")
  end

  defp broadcast_tx_event(rig_id, symbol_count, sample_count, duration_ms) do
    broadcast(rig_id, {:ale_tx, rig_id, %{
      symbols: symbol_count,
      samples: sample_count,
      duration_ms: duration_ms
    }})
  end

  defp broadcast(rig_id, message) do
    group = {:minutemodem, :rig, rig_id}
    for pid <- :pg.get_members(:minutemodem_pg, group) do
      send(pid, message)
    end
    :ok
  rescue
    _ -> :ok
  end
end
