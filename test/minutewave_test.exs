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

defmodule Minutewave.Dsp.PhyModemTest do
  use ExUnit.Case

  describe "facade dispatch" do
    test "raises a helpful error when no NIF module configured" do
      Application.delete_env(:minutewave, :phy_modem_nif)

      assert_raise RuntimeError, ~r/no NIF module configured/, fn ->
        Minutewave.Dsp.PhyModem.unified_mod_new(:qpsk, 9600)
      end
    end

    test "dispatches to the configured NIF module" do
      # A fake NIF impl, just to prove dispatch reaches the right module
      defmodule FakeNif do
        def unified_mod_new(constellation, sample_rate, symbol_rate, carrier_freq),
          do: {:fake, constellation, sample_rate, symbol_rate, carrier_freq}
      end

      Application.put_env(:minutewave, :phy_modem_nif, FakeNif)

      assert {:fake, :qpsk, 9600, nil, nil} =
               Minutewave.Dsp.PhyModem.unified_mod_new(:qpsk, 9600)

      assert {:fake, :psk8, 19200, 4800, 1500.0} =
               Minutewave.Dsp.PhyModem.unified_mod_new(:psk8, 19200, 4800, 1500.0)
    after
      Application.delete_env(:minutewave, :phy_modem_nif)
    end
  end
end
