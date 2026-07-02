defmodule Minutewave.ALE.Tod.Timing do
  @moduledoc """
  Timing recovery for the 4G TOD exchange, per MIL-STD-188-141D G.5.7.4.3
  (receiver computation) using the timing constants of G.5.5.11.

  The TOD response conveys sub-second time and slot error through *when* it
  arrives on air, not through fields. The responder transmits it exactly
  `T_Confirm` after the end of the TOD request. The requester measures the
  round-trip and backs out propagation delay and its own slot error:

      T_Burst        = T_TLC + T_preamble + T_payload   (on-air duration of 1 PDU)
      T_prop         = (T_Elapsed - T_Confirm - T_Burst) / 2
      T_ReqSlotLate  = T_SyncOffset - T_prop
      (correct local slot timing by T_ReqSlotLate)
      uncertainty    = TQ value + 1 ms      (Minutewave.ALE.Tod.accepted_uncertainty_ms/1)

  where `T_Elapsed` is the only runtime-measured quantity: the interval from the
  end of the requester's outbound request PDU to the arrival of the response,
  both stamped on the monotonic clock.

  ## INP defaults, not hard constants

  The timing values below are Initial Network Parameters (INPs) with the
  spec-default values from G.5.5.11. A given net may override them; requester
  and responder must agree, or the T_prop backout is wrong. Hold them in a
  `%Config{}` so a deployment can supply its own without touching this logic.
  """

  defmodule Config do
    @moduledoc "TOD/WALE timing parameters (INPs). Defaults per MIL-STD-188-141D G.5.5.11."

    @typedoc "All fields in milliseconds."
    @type t :: %__MODULE__{
            t_tune: number(),
            t_handshake: number(),
            t_tlc: number(),
            t_preamble_fast: number(),
            t_preamble_deep: number(),
            t_prop_max: number()
          }

    # G.5.5.11 defaults:
    #   T_tune 40, T_handshake 100  (=> T_Confirm 140)
    #   T_TLC 13.33
    #   T_preamble 120 (Fast) / 240 (Deep)
    #   T_propMax 80
    defstruct t_tune: 40,
              t_handshake: 100,
              t_tlc: 13.33,
              t_preamble_fast: 120,
              t_preamble_deep: 240,
              t_prop_max: 80
  end

  alias Minutewave.ALE.Tod

  @doc """
  `T_Confirm = T_tune + T_handshake` — the fixed delay the responder waits
  between the end of the request PDU and the start of the response (G.5.5.11.3).
  """
  @spec t_confirm(Config.t()) :: number()
  def t_confirm(%Config{} = c), do: c.t_tune + c.t_handshake

  @doc """
  Preamble duration (ms) for the given waveform: 120 (`:fast`) / 240 (`:deep`).
  """
  @spec t_preamble(Config.t(), :fast | :deep) :: number()
  def t_preamble(%Config{} = c, :fast), do: c.t_preamble_fast
  def t_preamble(%Config{} = c, :deep), do: c.t_preamble_deep

  @doc """
  On-air duration of a single PDU: `T_Burst = T_TLC + T_preamble + T_payload`.
  `t_payload_ms` is waveform/size-dependent and supplied by the caller (the
  modem knows the actual payload symbol count and rate for the response).
  """
  @spec t_burst(Config.t(), :fast | :deep, number()) :: number()
  def t_burst(%Config{} = c, waveform, t_payload_ms) do
    c.t_tlc + t_preamble(c, waveform) + t_payload_ms
  end

  @doc """
  Recover propagation delay and slot error from a completed TOD exchange.

  Inputs:
    * `t_elapsed_ms` - measured interval from end of the requester's request PDU
      to arrival of the response (monotonic).
    * `sync_offset_code` - the Sync Offset code (0..255) from the response.
    * `sign` - 1 if the request was late, 0 if early (response Sign field).
    * `tq` - the responder's advertised TQ code (0..7).
    * `waveform` - `:fast | :deep`, the waveform the response used.
    * `t_payload_ms` - on-air payload duration of the response PDU.
    * `config` - timing INPs.

  Returns `{:ok, %{t_prop_ms, t_req_slot_late_ms, slot_correction_ms,
  uncertainty_ms}}`, or `{:error, reason}` if the measurement is inconsistent
  (e.g. implied propagation delay is negative or exceeds `t_prop_max`, or the
  Sync Offset is `:no_report`).

  `slot_correction_ms` is the signed amount to adjust local slot timing by:
  a positive value means the requester's slot is late and should move earlier.
  """
  @spec recover(
          number(),
          0..255,
          0..1,
          0..7,
          :fast | :deep,
          number(),
          Config.t()
        ) ::
          {:ok,
           %{
             t_prop_ms: number(),
             t_req_slot_late_ms: number(),
             slot_correction_ms: number(),
             uncertainty_ms: non_neg_integer() | :infinity
           }}
          | {:error, atom()}
  def recover(t_elapsed_ms, sync_offset_code, sign, tq, waveform, t_payload_ms, %Config{} = c)
      when sign in 0..1 and tq in 0..7 do
    case Tod.sync_offset_decode(sync_offset_code) do
      :no_report ->
        {:error, :sync_offset_no_report}

      offset_mag ->
        # Sign: 1 = request was late (positive slot error), 0 = early (negative).
        t_sync_offset = if sign == 1, do: offset_mag, else: -offset_mag

        t_burst = t_burst(c, waveform, t_payload_ms)
        t_prop = (t_elapsed_ms - t_confirm(c) - t_burst) / 2

        cond do
          t_prop < 0 ->
            {:error, :negative_propagation}

          t_prop > c.t_prop_max ->
            {:error, :propagation_exceeds_max}

          true ->
            t_req_slot_late = t_sync_offset - t_prop

            {:ok,
             %{
               t_prop_ms: t_prop,
               t_req_slot_late_ms: t_req_slot_late,
               # correcting the local slot means shifting by -T_ReqSlotLate:
               # if we are late (positive), move earlier (negative correction).
               slot_correction_ms: -t_req_slot_late,
               uncertainty_ms: Tod.accepted_uncertainty_ms(tq)
             }}
        end
    end
  end
end
