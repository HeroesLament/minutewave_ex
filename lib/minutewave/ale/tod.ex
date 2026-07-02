defmodule Minutewave.ALE.Tod do
  @moduledoc """
  Spec codecs and constants for 4G (WALE) Time-of-Day distribution,
  per MIL-STD-188-141D Appendix G, section G.5.7.4.

  This module is pure and table-driven: it holds the encodings the TOD
  request/response exchange needs, with no process state and no FSM coupling,
  so it can be unit-tested against the standard's tables in isolation.

  ## What TOD is (G.5.7.4)

  GPS is the typical and preferred network time source. A PU lacking GPS may
  request time from a synchronized PU. A **TOD Request** is an asynchronous LSU
  call with Traffic Type = TOD (63); it is undirected (Called = broadcast,
  implicitly the Net Control PU) or directed (Called = a specific responder).
  The responder issues a precisely-timed **TOD_Response** carrying Min, Sec,
  Sync Offset, Sign, and TQ. The **milliseconds of TOD are conveyed by the
  timing of the PDU** (it is sent exactly T_Confirm after the request ends),
  not by a field. The requester recovers propagation delay and its own slot
  error from that timing (see `Minutewave.ALE.Tod.Timing`).

  ## Tables encoded here

    * **Traffic types (Table G-XII):** TOD = 63, Sync Check = 61,
      LQA Exchange = 62.
    * **Sync Offset codes (Table G-XVI):** a piecewise code<->milliseconds
      mapping for the slot-timing error the responder reports.
    * **Time quality codes (Table G-XVII):** the responder's advertised total
      time uncertainty. The requester sets its own uncertainty to the TQ
      value + 1 ms (G.5.7.4.3).
  """

  # --- Traffic types (Table G-XII) -------------------------------------------

  @traffic_type_sync_check 61
  @traffic_type_lqa_exchange 62
  @traffic_type_tod 63

  @doc "Traffic Type code for a TOD request/response (Table G-XII)."
  def traffic_type_tod, do: @traffic_type_tod

  @doc "Traffic Type code for a Sync Check (Table G-XII)."
  def traffic_type_sync_check, do: @traffic_type_sync_check

  @doc "Traffic Type code for an LQA Exchange (Table G-XII)."
  def traffic_type_lqa_exchange, do: @traffic_type_lqa_exchange

  # --- Time quality (Table G-XVII) -------------------------------------------

  # Total time uncertainty (ms) advertised by each TQ code. Code 0 is "none"
  # (a UTC PU); code 7 is unbounded/unknown. We represent 0 as 0 ms and 7 as
  # :infinity so the clock's arbitration can compare numerically.
  @tq_uncertainty_ms %{
    0 => 0,
    1 => 1,
    2 => 5,
    3 => 20,
    4 => 50,
    5 => 200,
    6 => 500,
    7 => :infinity
  }

  @doc """
  Total time uncertainty (ms) for a TQ code (Table G-XVII). Returns `:infinity`
  for code 7 (unbounded/unknown). Raises for codes outside 0..7.
  """
  @spec tq_to_uncertainty_ms(0..7) :: non_neg_integer() | :infinity
  def tq_to_uncertainty_ms(tq) when tq in 0..7, do: Map.fetch!(@tq_uncertainty_ms, tq)

  @doc """
  The uncertainty a *requester* adopts after accepting time from a responder
  advertising TQ code `tq`: the responder's uncertainty plus 1 ms (G.5.7.4.3,
  "Set its local time uncertainty IAW the TQ code plus 1 ms"). For TQ 7
  (unbounded) this is `:infinity`.
  """
  @spec accepted_uncertainty_ms(0..7) :: non_neg_integer() | :infinity
  def accepted_uncertainty_ms(7), do: :infinity
  def accepted_uncertainty_ms(tq) when tq in 0..6, do: tq_to_uncertainty_ms(tq) + 1

  @doc """
  Choose the smallest TQ code whose advertised uncertainty is >= our own
  uncertainty in ms — i.e. how a PU advertises its *own* time quality when
  responding. `:infinity` (or anything above 500 ms) maps to 7.
  """
  @spec uncertainty_ms_to_tq(non_neg_integer() | :infinity) :: 0..7
  def uncertainty_ms_to_tq(:infinity), do: 7

  def uncertainty_ms_to_tq(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms <= 0 -> 0
      ms <= 1 -> 1
      ms <= 5 -> 2
      ms <= 20 -> 3
      ms <= 50 -> 4
      ms <= 200 -> 5
      ms <= 500 -> 6
      true -> 7
    end
  end

  # --- Sync Offset codes (Table G-XVI) ---------------------------------------

  # Piecewise magnitude ladder:
  #   code   0..50  -> 2 * code                    (range    0 .. 100 ms)
  #   code  51..175 -> 100 + 10 * (code - 50)      (range  110 .. 1350 ms)
  #   code 176..254 -> 1350 + 50 * (code - 175)    (range 1400 .. 5300 ms)
  #   code 255      -> :no_report
  @sync_offset_no_report 255

  @doc """
  Decode a Sync Offset code (0..255) to its magnitude in milliseconds
  (Table G-XVI). Code 255 means "no report" and returns `:no_report`.
  """
  @spec sync_offset_decode(0..255) :: non_neg_integer() | :no_report
  def sync_offset_decode(@sync_offset_no_report), do: :no_report
  def sync_offset_decode(code) when code in 0..50, do: 2 * code
  def sync_offset_decode(code) when code in 51..175, do: 100 + 10 * (code - 50)
  def sync_offset_decode(code) when code in 176..254, do: 1350 + 50 * (code - 175)

  @doc """
  Encode a magnitude in milliseconds to the nearest Sync Offset code that does
  not *under*-report it (round up to the next representable magnitude, so the
  reported window always covers the true offset). Values above the ladder's max
  (5300 ms) clamp to code 254; negative input raises.

  Returns a code in 0..254. (255/"no report" is produced explicitly by the
  caller when there is nothing to report, not by this function.)
  """
  @spec sync_offset_encode(non_neg_integer()) :: 0..254
  def sync_offset_encode(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms <= 100 ->
        # 2*code >= ms  ->  code = ceil(ms/2)
        min(50, ceil_div(ms, 2))

      ms <= 1350 ->
        # 100 + 10*(code-50) >= ms  ->  code = 50 + ceil((ms-100)/10)
        50 + ceil_div(ms - 100, 10)

      ms <= 5300 ->
        # 1350 + 50*(code-175) >= ms  ->  code = 175 + ceil((ms-1350)/50)
        175 + ceil_div(ms - 1350, 50)

      true ->
        254
    end
  end

  @doc "The Sync Offset code meaning \"no report\" (255)."
  def sync_offset_no_report, do: @sync_offset_no_report

  defp ceil_div(n, d) when n <= 0, do: 0
  defp ceil_div(n, d), do: div(n + d - 1, d)
end
