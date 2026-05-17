defmodule Minutewave.Audio do
  @moduledoc """
  Facade for radio-side audio I/O. Dispatches to a consumer-supplied
  backend module implementing the `Minutewave.Audio.Backend` behaviour.

  Consumers register their backend via application config:

      config :minutewave, audio_backend: MyApp.Audio.Backend

  All minutewave protocol code (RxFSM, TxFSM, Arbiter) calls into this
  facade. The actual audio I/O happens through the configured module.

  ## Why a facade?

  The protocol code needs to subscribe to RX audio and submit TX audio
  without knowing whether the backend is a Membrane pipeline, an Android
  AAudio bridge, a channel simulator, or a file-based test harness. The
  facade decouples them.
  """

  def subscribe(rig_id),                       do: impl().subscribe(rig_id)
  def unsubscribe(rig_id),                     do: impl().unsubscribe(rig_id)
  def play_tx(rig_id, samples, rate, opts \\ []), do: impl().play_tx(rig_id, samples, rate, opts)
  def tx_active?(rig_id),                      do: impl().tx_active?(rig_id)
  def capabilities,                            do: impl().capabilities()

  defp impl do
    Application.get_env(:minutewave, :audio_backend) ||
      raise """
      Minutewave.Audio: no audio_backend configured.

      Add to your application's config:

          config :minutewave, audio_backend: MyApp.Audio.Backend

      where MyApp.Audio.Backend is a module implementing the
      `Minutewave.Audio.Backend` behaviour.
      """
  end
end
