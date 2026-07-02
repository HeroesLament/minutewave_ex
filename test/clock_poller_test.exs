defmodule Minutewave.Clock.PollerTest do
  use ExUnit.Case, async: false

  alias Minutewave.Clock

  # A pull source whose fixes are scripted via an Agent. read_fix/0 pops the
  # next scripted result; when exhausted it returns :no_fix.
  defmodule StubSource do
    @behaviour Minutewave.Clock.Source

    def start(results), do: Agent.start_link(fn -> results end, name: __MODULE__)
    def stop do
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
      :ok
    end

    @impl true
    def read_fix do
      Agent.get_and_update(__MODULE__, fn
        [h | t] -> {h, t}
        [] -> {:no_fix, []}
      end)
    end

    @impl true
    def name, do: "stub-source"

    @impl true
    def suggested_interval_ms, do: 50
  end

  setup do
    # A dedicated clock instance per test, low guard so we can drive states.
    {:ok, clock} = Clock.start_link(name: :poller_test_clock, guard_ms: 250, drift_ppm: 20)
    on_exit(fn -> if Process.alive?(clock), do: GenServer.stop(clock) end)
    %{clock: clock}
  end

  test "poller forwards a scripted fix into the clock, locking it", %{clock: clock} do
    mono = System.monotonic_time(:millisecond)
    now = System.os_time(:millisecond)

    {:ok, _agent} =
      StubSource.start([{:ok, %{protocol_time_ms: now, mono_ms: mono, uncertainty_ms: 2, stratum: 0}}])

    on_exit(&StubSource.stop/0)

    # Undisciplined to start.
    assert {:unsynced, _} = Clock.quality(:poller_test_clock)

    {:ok, poller} =
      Minutewave.Clock.Poller.start_link(
        source: StubSource,
        clock: clock,
        name: :poller_test_poller,
        interval_ms: 20
      )

    on_exit(fn -> if Process.alive?(poller), do: GenServer.stop(poller) end)

    # After the first poll the scripted fix should have disciplined the clock.
    Process.sleep(60)
    assert {q, unc} = Clock.quality(:poller_test_clock)
    assert q in [:locked, :holdover]
    assert unc <= 5
  end

  test "poller uses the source suggested_interval_ms when interval not given" do
    # Indirectly verified: start without interval_ms and confirm it still polls.
    mono = System.monotonic_time(:millisecond)
    now = System.os_time(:millisecond)

    {:ok, _agent} =
      StubSource.start([{:ok, %{protocol_time_ms: now, mono_ms: mono, uncertainty_ms: 2, stratum: 0}}])

    on_exit(&StubSource.stop/0)

    {:ok, poller} =
      Minutewave.Clock.Poller.start_link(
        source: StubSource,
        clock: :poller_test_clock,
        name: :poller_test_poller2
      )

    on_exit(fn -> if Process.alive?(poller), do: GenServer.stop(poller) end)

    # suggested_interval_ms is 50; within ~120ms it should have polled at least once.
    Process.sleep(120)
    assert {q, _} = Clock.quality(:poller_test_clock)
    assert q in [:locked, :holdover]
  end

  test ":no_fix results are dropped and leave the clock coasting" do
    {:ok, _agent} = StubSource.start([:no_fix, :no_fix])
    on_exit(&StubSource.stop/0)

    {:ok, poller} =
      Minutewave.Clock.Poller.start_link(
        source: StubSource,
        clock: :poller_test_clock,
        name: :poller_test_poller3,
        interval_ms: 20
      )

    on_exit(fn -> if Process.alive?(poller), do: GenServer.stop(poller) end)

    Process.sleep(60)
    # Never disciplined -> still unsynced, and the poller didn't crash.
    assert {:unsynced, _} = Clock.quality(:poller_test_clock)
    assert Process.alive?(poller)
  end
end
