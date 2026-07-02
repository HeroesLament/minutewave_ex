defmodule Minutewave.ALE.TodTest do
  use ExUnit.Case, async: true
  alias Minutewave.ALE.Tod

  describe "traffic types (Table G-XII)" do
    test "TOD, Sync Check, LQA Exchange codes" do
      assert Tod.traffic_type_tod() == 63
      assert Tod.traffic_type_sync_check() == 61
      assert Tod.traffic_type_lqa_exchange() == 62
    end
  end

  describe "TQ ladder (Table G-XVII)" do
    test "tq_to_uncertainty_ms matches the spec table exactly" do
      assert Tod.tq_to_uncertainty_ms(0) == 0
      assert Tod.tq_to_uncertainty_ms(1) == 1
      assert Tod.tq_to_uncertainty_ms(2) == 5
      assert Tod.tq_to_uncertainty_ms(3) == 20
      assert Tod.tq_to_uncertainty_ms(4) == 50
      assert Tod.tq_to_uncertainty_ms(5) == 200
      assert Tod.tq_to_uncertainty_ms(6) == 500
      assert Tod.tq_to_uncertainty_ms(7) == :infinity
    end

    test "accepted_uncertainty_ms is TQ value + 1ms (G.5.7.4.3)" do
      assert Tod.accepted_uncertainty_ms(0) == 1
      assert Tod.accepted_uncertainty_ms(2) == 6
      assert Tod.accepted_uncertainty_ms(6) == 501
      assert Tod.accepted_uncertainty_ms(7) == :infinity
    end

    test "uncertainty_ms_to_tq advertises conservatively (rounds up, never under-reports)" do
      assert Tod.uncertainty_ms_to_tq(0) == 0
      assert Tod.uncertainty_ms_to_tq(1) == 1
      # 3ms real uncertainty -> smallest covering code is 5ms = TQ 2
      assert Tod.uncertainty_ms_to_tq(3) == 2
      assert Tod.uncertainty_ms_to_tq(5) == 2
      assert Tod.uncertainty_ms_to_tq(200) == 5
      assert Tod.uncertainty_ms_to_tq(:infinity) == 7
      assert Tod.uncertainty_ms_to_tq(999_999) == 7
    end
  end

  describe "Sync Offset codec (Table G-XVI)" do
    test "decode boundaries across the three piecewise ranges" do
      assert Tod.sync_offset_decode(0) == 0
      assert Tod.sync_offset_decode(50) == 100
      assert Tod.sync_offset_decode(51) == 110
      assert Tod.sync_offset_decode(175) == 1350
      assert Tod.sync_offset_decode(176) == 1400
      assert Tod.sync_offset_decode(254) == 5300
      assert Tod.sync_offset_decode(255) == :no_report
    end

    test "encode rounds up so it never under-reports the true offset" do
      assert Tod.sync_offset_encode(0) == 0
      assert Tod.sync_offset_encode(1) == 1
      assert Tod.sync_offset_encode(100) == 50
      # 101ms cannot use code 50 (=100ms); must round up to code 51 (=110ms)
      assert Tod.sync_offset_encode(101) == 51
      assert Tod.sync_offset_encode(6000) == 254
    end

    test "encode/decode round-trip never loses coverage" do
      for ms <- [0, 1, 7, 42, 100, 101, 500, 1000, 1350, 1400, 3000, 5300] do
        code = Tod.sync_offset_encode(ms)
        decoded = Tod.sync_offset_decode(code)
        assert decoded >= ms, "code #{code} decoded #{decoded} < requested #{ms}"
      end
    end

    test "sync_offset_no_report is 255" do
      assert Tod.sync_offset_no_report() == 255
    end
  end
end
