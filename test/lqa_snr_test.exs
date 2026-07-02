defmodule Minutewave.ALE.LQASnrTest do
  use ExUnit.Case, async: false
  alias Minutewave.ALE.LQA
  alias Minutewave.Modem.Events

  describe "snr_score/1 (SNR dB -> 0..100)" do
    test "linear mapping with clamps: -10dB->0, +30dB->100" do
      assert LQA.snr_score(-10.0) == 0.0
      assert LQA.snr_score(-20.0) == 0.0
      assert LQA.snr_score(10.0) == 50.0
      assert LQA.snr_score(20.0) == 75.0
      assert LQA.snr_score(30.0) == 100.0
      assert LQA.snr_score(50.0) == 100.0
      assert LQA.snr_score(nil) == 0.0
    end
  end

  describe "record_observation direction + snr_db + lqa_score override" do
    setup do
      # Events is a per-rig GenServer; start one for our test rig.
      rig = :snr_test_rig

      case Events.start_link(rig_id: rig) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      Events.subscribe(rig, self())
      %{rig: rig}
    end

    test "rx observation defaults direction :rx and carries snr_db", %{rig: rig} do
      LQA.record_observation(rig, 0x00BB, 7_185_000, %{probe_corr: 80.0}, snr_db: 15.0)

      assert_receive {:ale, {:lqa_observation, obs}}, 500
      assert obs.direction == :rx
      assert obs.snr_db == 15.0
      # score came from the decode metrics (probe_corr present)
      assert obs.lqa_score > 0.0
    end

    test "tx observation records direction :tx with SNR-derived score", %{rig: rig} do
      # Peer reported wire SNR 30 -> 20 dB -> snr_score 75.0.
      LQA.record_observation(rig, 0x00BB, 7_185_000, %{snr_db: 20},
        direction: :tx,
        frame_type: "response",
        snr_db: 20,
        lqa_score: LQA.snr_score(20)
      )

      assert_receive {:ale, {:lqa_observation, obs}}, 500
      assert obs.direction == :tx
      assert obs.snr_db == 20
      assert obs.lqa_score == 75.0
    end

    test "lqa_score override wins over the decode formula", %{rig: rig} do
      # Even with strong decode metrics, an explicit override is used.
      LQA.record_observation(rig, 0x00BB, 7_185_000, %{probe_corr: 100.0}, lqa_score: 42.0)

      assert_receive {:ale, {:lqa_observation, obs}}, 500
      assert obs.lqa_score == 42.0
    end
  end
end
