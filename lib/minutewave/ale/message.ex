defmodule Minutewave.ALE.Message do
  @moduledoc """
  MIL-STD-188-141D 4G Message Protocol (Appendix G, G.5.6).

  The 4G message protocols carry text and binary data as an **unacknowledged**
  sequence of message PDUs. A message is fragmented into fixed 8-octet chunks,
  one per PDU (`Minutewave.ALE.PDU.TxtMessage` / `BinMessage`), and reassembled
  on receipt using the per-PDU Control field and Word (PDU) Countdown.

  This module owns everything *between* a whole message and the single-PDU codec
  in `Minutewave.ALE.PDU`:

    * the Control field (`[Padding:3][SOM:1][EOM:1]`, Figure G-31),
    * ASCII 7-bit + odd-parity octet coding for text (G.5.6.3),
    * fragmentation of a message into an ordered list of PDU structs, and
    * reassembly of a received PDU list back into the original message.

  It does **not** address, transmit, or persist anything — message PDUs are
  addressless payload riders whose from/to comes from the carrier PDU (a link
  setup PDU with M=1, or a Message Header PDU). Delivery is unacknowledged.

  ## Framing rules (G.5.6.1)

    * Each PDU carries up to 8 message octets; a message is at most 2048 octets
      (256 PDUs). Octets are sent in message order.
    * The Word (PDU) Countdown = (PDU count − 1) in the first PDU (SOM=1) and
      decrements to 0 in the final PDU (EOM=1).
    * The final PDU is padded to 8 octets — NUL for text, zero for binary — and
      its Control Padding field records how many octets are unused (0..7).
  """

  import Bitwise

  alias Minutewave.ALE.PDU

  @octets_per_pdu 8
  @max_pdus 256
  @max_message_octets @octets_per_pdu * @max_pdus

  @typedoc "Reassembled message result."
  @type text_result :: %{
          text: binary(),
          parity_errors: non_neg_integer(),
          error_positions: [non_neg_integer()],
          pdu_count: pos_integer()
        }

  # ===================================================================
  # Control field  (Figure G-31:  [Padding:3][SOM:1][EOM:1] = 5 bits)
  # ===================================================================

  @doc "Pack a Control field from its parts into the 5-bit PDU control value."
  @spec pack_control(0..7, boolean(), boolean()) :: 0..31
  def pack_control(padding, som, eom)
      when padding in 0..7 and is_boolean(som) and is_boolean(eom) do
    (padding <<< 2) ||| (b(som) <<< 1) ||| b(eom)
  end

  @doc "Unpack a 5-bit PDU control value into `%{padding:, som:, eom:}`."
  @spec unpack_control(0..31) :: %{padding: 0..7, som: boolean(), eom: boolean()}
  def unpack_control(control) when control in 0..31 do
    %{
      padding: control >>> 2 &&& 0x7,
      som: (control >>> 1 &&& 0x1) == 1,
      eom: (control &&& 0x1) == 1
    }
  end

  # ===================================================================
  # ASCII odd-parity octet coding (G.5.6.3)
  # ===================================================================

  @doc """
  Encode a 7-bit ASCII code point (0..127) into a text octet whose most
  significant bit is set so the whole octet has **odd** parity.
  """
  @spec put_parity(0..127) :: 0..255
  def put_parity(char) when char in 0..127 do
    if rem(popcount(char), 2) == 0, do: char ||| 0x80, else: char
  end

  @doc """
  Decode a text octet: returns `{char, parity_ok?}` where `char` is the low 7
  bits and `parity_ok?` is true iff the octet has odd parity.
  """
  @spec check_parity(0..255) :: {0..127, boolean()}
  def check_parity(octet) when octet in 0..255 do
    {octet &&& 0x7F, rem(popcount(octet), 2) == 1}
  end

  # ===================================================================
  # Fragmentation  (message -> [PDU])
  # ===================================================================

  @doc """
  Fragment a text message into an ordered list of `%PDU.TxtMessage{}`.

  `text` must be 7-bit ASCII, 1..2048 octets. Each octet is odd-parity coded.
  Returns `{:ok, [pdu]}` or `{:error, reason}`.
  """
  @spec fragment_text(binary()) :: {:ok, [PDU.TxtMessage.t()]} | {:error, term()}
  def fragment_text(text) when is_binary(text) do
    with :ok <- validate_length(byte_size(text)),
         :ok <- validate_ascii(text) do
      coded = for <<c <- text>>, into: <<>>, do: <<put_parity(c)>>

      pdus =
        coded
        |> chunk_octets()
        |> build_pdus(fn control, countdown, chunk ->
          %PDU.TxtMessage{control: control, countdown: countdown, text: chunk}
        end)

      {:ok, pdus}
    end
  end

  @doc """
  Fragment a binary message into an ordered list of `%PDU.BinMessage{}`.
  `data` must be 1..2048 octets. Returns `{:ok, [pdu]}` or `{:error, reason}`.
  """
  @spec fragment_binary(binary()) :: {:ok, [PDU.BinMessage.t()]} | {:error, term()}
  def fragment_binary(data) when is_binary(data) do
    with :ok <- validate_length(byte_size(data)) do
      pdus =
        data
        |> chunk_octets()
        |> build_pdus(fn control, countdown, chunk ->
          %PDU.BinMessage{control: control, countdown: countdown, data: chunk}
        end)

      {:ok, pdus}
    end
  end

  # Split an octet binary into <=8-octet chunks and stamp control/countdown.
  defp build_pdus(chunks, make_pdu) do
    n = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, i} ->
      som = i == 0
      eom = i == n - 1
      padding = if eom, do: @octets_per_pdu - byte_size(chunk), else: 0
      countdown = n - 1 - i
      make_pdu.(pack_control(padding, som, eom), countdown, chunk)
    end)
  end

  # ===================================================================
  # Reassembly  ([PDU] -> message)
  # ===================================================================

  @doc """
  Reassemble an ordered list of received `%PDU.TxtMessage{}` into text.

  Validates framing (SOM on first, EOM on last, countdown N-1..0), strips
  padding, and checks odd parity per octet. Parity failures are reported via
  `parity_errors`/`error_positions`; the low 7 bits are still returned so the
  caller can render an error marker where it chooses.
  """
  @spec reassemble_text([PDU.TxtMessage.t()]) :: {:ok, text_result()} | {:error, term()}
  def reassemble_text(pdus) do
    with :ok <- validate_framing(pdus, & &1.control),
         octets when is_binary(octets) <- collect_octets(pdus, & &1.text) do
      {chars, errors, positions} = strip_parity(octets)
      {:ok,
       %{
         text: chars,
         parity_errors: errors,
         error_positions: positions,
         pdu_count: length(pdus)
       }}
    end
  end

  @doc """
  Reassemble an ordered list of received `%PDU.BinMessage{}` into a binary.
  Validates framing and strips final-PDU padding. Returns `{:ok, binary}`.
  """
  @spec reassemble_binary([PDU.BinMessage.t()]) :: {:ok, binary()} | {:error, term()}
  def reassemble_binary(pdus) do
    with :ok <- validate_framing(pdus, & &1.control),
         octets when is_binary(octets) <- collect_octets(pdus, & &1.data) do
      {:ok, octets}
    end
  end

  # Concatenate each PDU's content, honoring the final PDU's Padding count.
  # Robust for both text (decode trims trailing NULs) and binary (kept whole):
  # every chunk is re-padded to 8 then sliced to its true content length.
  defp collect_octets(pdus, field) do
    n = length(pdus)

    pdus
    |> Enum.with_index()
    |> Enum.reduce(<<>>, fn {pdu, i}, acc ->
      %{padding: padding, eom: eom} = unpack_control(pdu.control)
      keep = if eom or i == n - 1, do: @octets_per_pdu - padding, else: @octets_per_pdu
      chunk = pad8(field.(pdu))
      acc <> binary_part(chunk, 0, max(keep, 0))
    end)
  end

  # ===================================================================
  # Validation
  # ===================================================================

  defp validate_length(0), do: {:error, :empty_message}
  defp validate_length(n) when n > @max_message_octets, do: {:error, {:too_long, n, @max_message_octets}}
  defp validate_length(_), do: :ok

  defp validate_ascii(text) do
    if Enum.all?(:binary.bin_to_list(text), &(&1 <= 127)),
      do: :ok,
      else: {:error, :non_ascii}
  end

  # SOM on first, EOM on last, exactly one of each, countdown = (N-1)..0.
  defp validate_framing([], _control_of), do: {:error, :no_pdus}

  defp validate_framing(pdus, control_of) do
    n = length(pdus)
    parts = Enum.map(pdus, fn p -> unpack_control(control_of.(p)) end)
    countdowns = Enum.map(pdus, & &1.countdown)

    cond do
      n > @max_pdus -> {:error, {:too_many_pdus, n}}
      not (parts |> hd() |> Map.get(:som)) -> {:error, :missing_som}
      not (parts |> List.last() |> Map.get(:eom)) -> {:error, :missing_eom}
      Enum.count(parts, & &1.som) != 1 -> {:error, :multiple_som}
      Enum.count(parts, & &1.eom) != 1 -> {:error, :multiple_eom}
      countdowns != Enum.to_list((n - 1)..0//-1) -> {:error, {:bad_countdown, countdowns}}
      true -> :ok
    end
  end

  # ===================================================================
  # Bit / octet helpers
  # ===================================================================

  # Split into 8-octet chunks; the final chunk may be 1..8 octets.
  defp chunk_octets(bin), do: do_chunk(bin, [])

  defp do_chunk(<<>>, acc), do: Enum.reverse(acc)

  defp do_chunk(bin, acc) when byte_size(bin) > @octets_per_pdu do
    <<chunk::binary-size(@octets_per_pdu), rest::binary>> = bin
    do_chunk(rest, [chunk | acc])
  end

  defp do_chunk(bin, acc), do: Enum.reverse([bin | acc])

  defp strip_parity(octets) do
    octets
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce({[], 0, []}, fn {oct, idx}, {chars, errs, pos} ->
      {char, ok?} = check_parity(oct)
      if ok?,
        do: {[char | chars], errs, pos},
        else: {[char | chars], errs + 1, [idx | pos]}
    end)
    |> then(fn {chars, errs, pos} ->
      {chars |> Enum.reverse() |> :binary.list_to_bin(), errs, Enum.reverse(pos)}
    end)
  end

  defp pad8(bin) when byte_size(bin) >= @octets_per_pdu, do: binary_part(bin, 0, @octets_per_pdu)
  defp pad8(bin), do: bin <> :binary.copy(<<0>>, @octets_per_pdu - byte_size(bin))

  defp popcount(x), do: Enum.reduce(0..7, 0, fn i, acc -> acc + (x >>> i &&& 1) end)

  defp b(true), do: 1
  defp b(false), do: 0
end
