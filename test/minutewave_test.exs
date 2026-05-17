defmodule MinutewaveTest do
  use ExUnit.Case
  doctest Minutewave

  describe "module structure" do
    test "Minutewave is loaded" do
      assert Code.ensure_loaded?(Minutewave)
    end

    test "Audio.Backend behaviour is defined" do
      assert Code.ensure_loaded?(Minutewave.Audio.Backend)
      callbacks = Minutewave.Audio.Backend.behaviour_info(:callbacks)
      assert {:play_tx, 4} in callbacks
      assert {:start_rx, 2} in callbacks
      assert {:stop_rx, 1} in callbacks
      assert {:tx_active?, 1} in callbacks
      assert {:capabilities, 0} in callbacks
    end

    test "Rig.Control behaviour is defined" do
      assert Code.ensure_loaded?(Minutewave.Rig.Control)
      callbacks = Minutewave.Rig.Control.behaviour_info(:callbacks)
      assert {:acquire_tx, 2} in callbacks
      assert {:release_tx, 1} in callbacks
      assert {:get_frequency, 1} in callbacks
      assert {:set_frequency, 2} in callbacks
      assert {:capabilities, 0} in callbacks
    end
  end
end
