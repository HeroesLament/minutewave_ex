defmodule Minutewave.RigStateTest do
  use ExUnit.Case, async: false
  alias Minutewave.RigState

  setup do
    # RigState may already be started by the application; ensure the table exists.
    case RigState.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Clean any residue from prior tests.
    for rig <- RigState.rigs(), do: RigState.clear(rig)
    :ok
  end

  test "publish/get round-trips a per-rig snapshot" do
    RigState.publish(:t_rig, %{
      link_state: :scanning,
      current_freq_hz: 7_185_000,
      channels: [1, 2]
    })

    snap = RigState.get(:t_rig)
    assert snap.link_state == :scanning
    assert snap.current_freq_hz == 7_185_000
    assert length(snap.channels) == 2
  end

  test "get returns nil for an absent rig" do
    assert RigState.get(:never_published) == nil
  end

  test "field/3 reads one key with a default fallback" do
    RigState.publish(:t_rig, %{link_state: :idle})
    assert RigState.field(:t_rig, :link_state) == :idle
    assert RigState.field(:t_rig, :missing, :default) == :default
    assert RigState.field(:absent_rig, :anything, :fallback) == :fallback
  end

  test "update/2 merges without clobbering other fields" do
    RigState.publish(:t_rig, %{link_state: :scanning, channels: [1, 2, 3], scan_index: 0})
    RigState.update(:t_rig, %{scan_index: 2, current_freq_hz: 14_109_000})
    snap = RigState.get(:t_rig)
    # merged
    assert snap.scan_index == 2
    assert snap.current_freq_hz == 14_109_000
    # preserved
    assert snap.link_state == :scanning
    assert length(snap.channels) == 3
  end

  test "multiple rigs are isolated by rig_id" do
    RigState.publish(:rig_a, %{current_freq_hz: 7_185_000, channels: [1, 2]})
    RigState.publish(:rig_b, %{current_freq_hz: 3_596_000, channels: [1, 2, 3]})

    assert RigState.field(:rig_a, :current_freq_hz) == 7_185_000
    assert RigState.field(:rig_b, :current_freq_hz) == 3_596_000
    assert length(RigState.field(:rig_a, :channels)) == 2
    assert length(RigState.field(:rig_b, :channels)) == 3

    all = RigState.all()
    assert map_size(all) == 2
    assert Map.has_key?(all, :rig_a)
    assert Map.has_key?(all, :rig_b)
  end

  test "clear/1 removes only the targeted rig" do
    RigState.publish(:rig_a, %{link_state: :scanning})
    RigState.publish(:rig_b, %{link_state: :scanning})
    RigState.clear(:rig_a)

    assert RigState.get(:rig_a) == nil
    refute RigState.get(:rig_b) == nil
    assert RigState.rigs() == [:rig_b]
  end
end
