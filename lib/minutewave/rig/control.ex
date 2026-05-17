defmodule Minutewave.Rig.Control do
  @moduledoc """
  Facade for radio control. Dispatches to a consumer-supplied backend
  module implementing the `Minutewave.Rig.Control.Behaviour` behaviour.

  Consumers register their backend via application config:

      config :minutewave, rig_control: MyApp.Rig.StubControl

  Same pattern as `Minutewave.Audio` and `Minutewave.Dsp.PhyModem`.
  """

  def acquire_tx(rig_id, tag),     do: impl().acquire_tx(rig_id, tag)
  def release_tx(rig_id, tag),     do: impl().release_tx(rig_id, tag)
  def get_frequency(rig_id),       do: impl().get_frequency(rig_id)
  def set_frequency(rig_id, hz),   do: impl().set_frequency(rig_id, hz)
  def get_mode(rig_id),            do: impl().get_mode(rig_id)
  def set_mode(rig_id, mode),      do: impl().set_mode(rig_id, mode)
  def status(rig_id),              do: impl().status(rig_id)
  def capabilities,                do: impl().capabilities()

  defp impl do
    Application.get_env(:minutewave, :rig_control) ||
      raise """
      Minutewave.Rig.Control: no rig_control backend configured.

      Add to your application config:

          config :minutewave, rig_control: MyApp.Rig.MyControl
      """
  end
end
