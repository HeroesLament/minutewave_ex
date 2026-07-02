defmodule Minutewave.ALE.ACSTest do
  use ExUnit.Case, async: false
  alias Minutewave.ALE.ACS
  alias Minutewave.RigState

  defmodule StubStore do
    @behaviour Minutewave.ALE.LQA.Store
    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def set(obs), do: Agent.update(__MODULE__, fn _ -> obs end)

    @impl true
    def recent_observations(_rig, _dest, freq_list, _opts) do
      Agent.get(__MODULE__, & &1) |> Enum.filter(&(&1.freq_hz in freq_list))
    end

    @impl true
    def last_heard_per_freq(_rig, _freq_list, _opts), do: %{}
  end

  @chans [%{freq_hz: 3_596_000}, %{freq_hz: 7_185_000}, %{freq_hz: 14_109_000}]

  setup do
    Application.put_env(:minutewave, :lqa_store, StubStore)

    case Registry.start_link(keys: :unique, name: Minutewave.Rig.InstanceRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case RigState.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case StubStore.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    StubStore.set([])
    on_exit(fn -> Application.delete_env(:minutewave, :lqa_store) end)
    :ok
  end

  defp start_acs(rig_id, opts \\ []) do
    {:ok, pid} = ACS.start_link(Keyword.merge([rig_id: rig_id], opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "cold start with no history returns config order, basis :cold_start" do
    RigState.publish(:r1, %{channels: @chans})
    start_acs(:r1, cold_start: :config_order)

    ranked = ACS.rank(:r1, 0x00BB)
    assert Enum.map(ranked, & &1.freq_hz) == [3_596_000, 7_185_000, 14_109_000]
    assert Enum.all?(ranked, &(&1.basis == :cold_start))
    assert %{freq_hz: 3_596_000, basis: :cold_start} = ACS.best(:r1, 0x00BB)
  end

  test "highest_first cold start orders by descending frequency" do
    RigState.publish(:r2, %{channels: @chans})
    start_acs(:r2, cold_start: :highest_first)

    ranked = ACS.rank(:r2, 0x00BB)
    assert Enum.map(ranked, & &1.freq_hz) == [14_109_000, 7_185_000, 3_596_000]
  end

  test "LQA history overrides cold start and tags basis :lqa" do
    RigState.publish(:r3, %{channels: @chans})
    start_acs(:r3)

    now = DateTime.utc_now()

    StubStore.set([
      %{freq_hz: 14_109_000, timestamp: now, lqa_score: 85.0},
      %{freq_hz: 7_185_000, timestamp: now, lqa_score: 40.0}
    ])

    ranked = ACS.rank(:r3, 0x00BB)
    assert [%{freq_hz: 14_109_000, basis: :lqa} | _] = ranked
    assert Enum.all?(ranked, &(&1.basis == :lqa))
    assert %{freq_hz: 14_109_000, basis: :lqa} = ACS.best(:r3, 0x00BB)
  end

  test "no channels yields an error from best/2" do
    RigState.publish(:r4, %{channels: []})
    start_acs(:r4)
    assert ACS.rank(:r4, 0x00BB) == []
    assert ACS.best(:r4, 0x00BB) == {:error, :no_channels}
  end
end
