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

  describe "application supervision" do
    test "Minutewave.Modem.Registry is started" do
      assert is_pid(Process.whereis(Minutewave.Modem.Registry))
    end

    test "Registry accepts via-tuple registration" do
      name = {:via, Registry, {Minutewave.Modem.Registry, {:test_rig, :events}}}
      {:ok, pid} = Agent.start_link(fn -> nil end, name: name)
      assert Process.whereis(Minutewave.Modem.Registry) |> is_pid()
      assert Registry.lookup(Minutewave.Modem.Registry, {:test_rig, :events}) == [{pid, nil}]
      Agent.stop(pid)
    end
  end
end

defmodule Minutewave.Modem.EventsTest do
  use ExUnit.Case

  alias Minutewave.Modem.Events

  test "subscribe + broadcast + unsubscribe round trip" do
    rig_id = :"test_rig_#{System.unique_integer([:positive])}"

    {:ok, _pid} = Events.start_link(rig_id: rig_id)

    :ok = Events.subscribe(rig_id, self())

    Events.broadcast(rig_id, {:modem, {:rx_data, "hello", :first}})
    assert_receive {:modem, {:rx_data, "hello", :first}}, 500

    :ok = Events.unsubscribe(rig_id, self())

    Events.broadcast(rig_id, {:modem, {:rx_data, "after_unsubscribe", :first}})
    refute_receive {:modem, _}, 100
  end

  test "subscribe with :tx filter only receives tx events" do
    rig_id = :"test_rig_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Events.start_link(rig_id: rig_id)

    :ok = Events.subscribe(rig_id, self(), filter: :tx)

    Events.broadcast(rig_id, {:modem, {:tx_status, %{state: :idle}}})
    Events.broadcast(rig_id, {:modem, {:rx_data, "no", :first}})

    assert_receive {:modem, {:tx_status, _}}, 500
    refute_receive {:modem, {:rx_data, _, _}}, 100
  end
end

defmodule Minutewave.Dsp.DemodOutputTest do
  use ExUnit.Case

  alias Minutewave.Dsp.DemodOutput

  test "Symbols struct" do
    s = %DemodOutput.Symbols{data: [0, 1, 2, 3], timing_offset: 5}
    assert s.data == [0, 1, 2, 3]
    assert s.timing_offset == 5
  end

  test "IQ struct + slice/2 QPSK" do
    iq = %DemodOutput.IQ{
      data: [{1.0, 0.0}, {0.0, 1.0}, {-1.0, 0.0}, {0.0, -1.0}],
      timing_offset: 0
    }

    result = DemodOutput.slice(iq, :qpsk)
    assert %DemodOutput.Symbols{} = result
    # One symbol per quadrant
    assert length(result.data) == 4
    assert Enum.uniq(result.data) |> length() == 4
  end

  test "slice/2 BPSK" do
    iq = %DemodOutput.IQ{
      data: [{1.0, 0.0}, {-1.0, 0.0}, {0.5, 0.1}, {-0.5, -0.1}],
      timing_offset: 0
    }

    assert %DemodOutput.Symbols{data: [0, 1, 0, 1]} = DemodOutput.slice(iq, :bpsk)
  end

  test "slice/2 is identity on Symbols" do
    s = %DemodOutput.Symbols{data: [0, 1, 2, 3]}
    assert ^s = DemodOutput.slice(s, :qpsk)
  end
end
