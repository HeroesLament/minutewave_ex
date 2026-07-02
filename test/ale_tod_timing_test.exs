defmodule Minutewave.ALE.Tod.TimingTest do
  use ExUnit.Case, async: true
  alias Minutewave.ALE.Tod.Timing
  alias Minutewave.ALE.Tod.Timing.Config

  setup do
    %{config: %Config{}}
  end

  describe "timing constants (G.5.5.11)" do
    test "t_confirm = t_tune + t_handshake = 140ms default", %{config: c} do
      assert Timing.t_confirm(c) == 140
    end

    test "t_preamble per waveform: 120 fast / 240 deep", %{config: c} do
      assert Timing.t_preamble(c, :fast) == 120
      assert Timing.t_preamble(c, :deep) == 240
    end

    test "t_burst = t_tlc + t_preamble + t_payload", %{config: c} do
      # 13.33 + 120 + 200 = 333.33
      assert_in_delta Timing.t_burst(c, :fast, 200), 333.33, 0.01
      # 13.33 + 240 + 0 = 253.33
      assert_in_delta Timing.t_burst(c, :deep, 0), 253.33, 0.01
    end
  end

  describe "recover/7 (G.5.7.4.3)" do
    test "backs out propagation delay and slot error from a known exchange", %{config: c} do
      # Construct: fast, payload 200 => T_Burst = 333.33; T_Confirm = 140.
      # True T_prop = 30 => T_Elapsed = 2*30 + 140 + 333.33 = 533.33.
      t_elapsed = 2 * 30 + Timing.t_confirm(c) + Timing.t_burst(c, :fast, 200)
      # sync offset code 25 => 50ms; sign 1 (late); TQ 3.
      {:ok, r} = Timing.recover(t_elapsed, 25, 1, 3, :fast, 200, c)

      assert_in_delta r.t_prop_ms, 30, 0.01
      # T_ReqSlotLate = T_SyncOffset - T_prop = 50 - 30 = 20
      assert_in_delta r.t_req_slot_late_ms, 20, 0.01
      # slot correction is the negative (we are late, move earlier)
      assert_in_delta r.slot_correction_ms, -20, 0.01
      # uncertainty = TQ(3)=20ms + 1 = 21
      assert r.uncertainty_ms == 21
    end

    test "early request yields negative sync offset", %{config: c} do
      t_elapsed = 2 * 30 + Timing.t_confirm(c) + Timing.t_burst(c, :fast, 0)
      # sign 0 (early): T_SyncOffset = -50, T_ReqSlotLate = -50 - 30 = -80
      {:ok, r} = Timing.recover(t_elapsed, 25, 0, 1, :fast, 0, c)
      assert_in_delta r.t_req_slot_late_ms, -80, 0.01
      assert_in_delta r.slot_correction_ms, 80, 0.01
    end

    test "rejects a no-report sync offset (code 255)", %{config: c} do
      assert {:error, :sync_offset_no_report} =
               Timing.recover(500, 255, 1, 3, :fast, 200, c)
    end

    test "rejects an implausibly small T_Elapsed (negative propagation)", %{config: c} do
      assert {:error, :negative_propagation} =
               Timing.recover(400, 25, 1, 3, :fast, 200, c)
    end

    test "rejects propagation beyond t_prop_max", %{config: c} do
      assert {:error, :propagation_exceeds_max} =
               Timing.recover(2000, 25, 1, 3, :fast, 200, c)
    end
  end
end
