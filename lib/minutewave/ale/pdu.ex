defmodule Minutewave.ALE.PDU do
  @moduledoc """
  MIL-STD-188-141D 4G ALE Protocol Data Units.

  Each PDU is a 96-bit structure with:
  - Protocol identifier (3 bits)
  - Type-specific fields
  - CRC-16 (16 bits)

  PDUs are transmitted LSB first within each field.
  """

  import Bitwise

  # Protocol identifiers (3 bits) -- per MIL-STD-188-141D Table G-XI
  @proto_text 0b000
  @proto_binary 0b001
  @proto_lsu 0b010
  @proto_util 0b011

  # LSU types (3 bits)
  @lsu_type_req 0b000
  @lsu_type_conf 0b001
  @lsu_type_term 0b010
  @lsu_type_status 0b011

  # Utility PDU subtypes. The Utility protocol (011, Table G-XI) shares its
  # code across Message Header (G.5.6.2), TOD Response and Data Fill (G.5.7);
  # they are disambiguated by the top 3 bits of the 5-bit Protocol-Specific
  # field (the low 2 bits are V and M). Per Figures G-28 / G-32 / G-33.
  @util_subtype_msg_hdr 0b000
  @util_subtype_tod 0b101

  # CRC polynomial: x^16 + x^12 + x^8 + x^7 + x^4 + x^3 + x + 1
  # Represented as 0x9299 (bit-reversed form used in spec)
  @crc_poly 0x9299
  @crc_init 0xFFFF

  # Every 4G PDU is a fixed 96-bit / 12-octet structure (Figure G-11).
  @pdu_octets 12

  # -------------------------------------------------------------------
  # LSU Request
  # -------------------------------------------------------------------

  defmodule LsuReq do
    @moduledoc """
    Link Setup Request PDU.

    Sent by calling station to initiate a link.

    Fields (96 bits total):
    - proto: 3 bits (010)
    - lsu_type: 3 bits (000)
    - v: 1 bit - voice capability
    - m: 1 bit - more PDUs follow
    - ec: 2 bits - equipment class
    - traf_type: 6 bits - traffic type
    - caller_addr: 16 bits
    - called_addr: 16 bits
    - assigned_subchannels: 16 bits
    - occupied_subchannels: 16 bits
    - crc: 16 bits
    """

    defstruct [
      :caller_addr,
      :called_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      traffic_type: 0,
      assigned_subchannels: 0,
      occupied_subchannels: 0
    ]

    @type t :: %__MODULE__{
            caller_addr: non_neg_integer(),
            called_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            equipment_class: 0..3,
            traffic_type: 0..63,
            assigned_subchannels: non_neg_integer(),
            occupied_subchannels: non_neg_integer()
          }
  end

  # -------------------------------------------------------------------
  # LSU Confirm
  # -------------------------------------------------------------------

  defmodule LsuConf do
    @moduledoc """
    Link Setup Confirmation PDU.

    Sent by called station to confirm link establishment.
    """

    defstruct [
      :caller_addr,
      :called_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      snr: 0,
      tx_subchannels: 0,
      rx_subchannels: 0
    ]

    @type t :: %__MODULE__{
            caller_addr: non_neg_integer(),
            called_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            equipment_class: 0..3,
            snr: 0..63,
            tx_subchannels: non_neg_integer(),
            rx_subchannels: non_neg_integer()
          }
  end

  # -------------------------------------------------------------------
  # LSU Terminate
  # -------------------------------------------------------------------

  defmodule LsuTerm do
    @moduledoc """
    Link Termination PDU.

    Sent to terminate an established link.
    """

    # Termination reason codes
    @reason_normal 0
    @reason_timeout 1
    @reason_busy 2
    @reason_channel_busy 3

    defstruct [
      :caller_addr,
      :called_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      reason: 0
    ]

    @type t :: %__MODULE__{
            caller_addr: non_neg_integer(),
            called_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            equipment_class: 0..3,
            reason: non_neg_integer()
          }

    def reason_normal, do: @reason_normal
    def reason_timeout, do: @reason_timeout
    def reason_busy, do: @reason_busy
    def reason_channel_busy, do: @reason_channel_busy
  end

  # -------------------------------------------------------------------
  # LSU Status
  # -------------------------------------------------------------------

  defmodule LsuStatus do
    @moduledoc """
    Link Status PDU.

    Reports link status information.
    """

    defstruct [
      :caller_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      status: 0,
      count: 0,
      assigned_subchannels: 0
    ]

    @type t :: %__MODULE__{
            caller_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            equipment_class: 0..3,
            status: non_neg_integer(),
            count: non_neg_integer(),
            assigned_subchannels: non_neg_integer()
          }
  end

  # -------------------------------------------------------------------
  # Text Message (AMD)
  # -------------------------------------------------------------------

  defmodule TxtMessage do
    @moduledoc """
    Text Message PDU for AMD (Automatic Message Display).

    Carries short text messages during or after linking.
    """

    defstruct control: 0,
              countdown: 0,
              text: <<>>

    @type t :: %__MODULE__{
            control: non_neg_integer(),
            countdown: non_neg_integer(),
            text: binary()
          }
  end

  # -------------------------------------------------------------------
  # Binary Message
  # -------------------------------------------------------------------

  defmodule BinMessage do
    @moduledoc """
    Binary Message PDU.

    Carries binary data.
    """

    defstruct control: 0,
              countdown: 0,
              data: <<>>

    @type t :: %__MODULE__{
            control: non_neg_integer(),
            countdown: non_neg_integer(),
            data: binary()
          }
  end

  # -------------------------------------------------------------------
  # Message Header (Figure G-28)
  # -------------------------------------------------------------------

  defmodule MsgHdr do
    @moduledoc """
    Message Header PDU (MIL-STD-188-141D G.5.6.2, Figure G-28).

    Leads a "stand-alone" message transmission (one not piggybacked on a link
    setup PDU). Carries the WALE addresses of the sender and recipient; the
    following Text/Binary Message PDUs are addressless and inherit their from/to
    from this header. `M` is always 1 (message PDUs follow). The 4-octet
    `purpose` is locally defined and not standardized.
    """

    defstruct [
      :sender_addr,
      :recipient_addr,
      voice: false,
      more: true,
      purpose: <<0, 0, 0, 0>>
    ]

    @type t :: %__MODULE__{
            sender_addr: non_neg_integer(),
            recipient_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            purpose: binary()
          }
  end

  # -------------------------------------------------------------------
  # Time of Day Response
  # -------------------------------------------------------------------

  defmodule TodResponse do
    @moduledoc """
    Time of Day Response PDU.

    Returns time synchronization information.
    """

    defstruct [
      :caller_addr,
      :responder_addr,
      voice: false,
      more: false,
      equipment_class: 0,
      sync_sign: 0,
      sync_tq: 0,
      sync_mag: 0,
      coarse_min: 0,
      coarse_sec: 0
    ]

    @type t :: %__MODULE__{
            caller_addr: non_neg_integer(),
            responder_addr: non_neg_integer(),
            voice: boolean(),
            more: boolean(),
            equipment_class: 0..3,
            sync_sign: 0..3,
            sync_tq: 0..7,
            sync_mag: non_neg_integer(),
            coarse_min: non_neg_integer(),
            coarse_sec: non_neg_integer()
          }
  end

  # -------------------------------------------------------------------
  # Encoding
  # -------------------------------------------------------------------

  @doc """
  Encode a PDU struct to a 96-bit binary (12 bytes).
  CRC is computed and appended.
  """
  def encode(%LsuReq{} = pdu) do
    # Build the 80-bit payload (before CRC)
    payload =
      <<
        # Byte 0: proto(3) + lsu_type(3) + v(1) + m(1)
        @proto_lsu::3,
        @lsu_type_req::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        # Byte 1: ec(2) + traf_type(6)
        pdu.equipment_class::2,
        pdu.traffic_type::6,
        # Bytes 2-3: caller_addr (16 bits, little endian)
        pdu.caller_addr::little-16,
        # Bytes 4-5: called_addr (16 bits, little endian)
        pdu.called_addr::little-16,
        # Bytes 6-7: assigned_subchannels (16 bits, little endian)
        pdu.assigned_subchannels::little-16,
        # Bytes 8-9: occupied_subchannels (16 bits, little endian)
        pdu.occupied_subchannels::little-16
      >>

    append_crc(payload)
  end

  def encode(%LsuConf{} = pdu) do
    payload =
      <<
        @proto_lsu::3,
        1::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        pdu.equipment_class::2,
        pdu.snr::6,
        pdu.caller_addr::little-16,
        pdu.called_addr::little-16,
        pdu.tx_subchannels::little-16,
        pdu.rx_subchannels::little-16
      >>

    append_crc(payload)
  end

  def encode(%LsuTerm{} = pdu) do
    payload =
      <<
        @proto_lsu::3,
        @lsu_type_term::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        pdu.equipment_class::2,
        pdu.reason::6,
        pdu.caller_addr::little-16,
        pdu.called_addr::little-16,
        # Padding to fill 80 bits
        0::32
      >>

    append_crc(payload)
  end

  def encode(%LsuStatus{} = pdu) do
    payload =
      <<
        @proto_lsu::3,
        @lsu_type_status::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        pdu.equipment_class::2,
        pdu.status::6,
        pdu.caller_addr::little-16,
        pdu.count::8,
        0::8,
        pdu.assigned_subchannels::little-16,
        0::16
      >>

    append_crc(payload)
  end

  def encode(%TxtMessage{} = pdu) do
    # Pad or truncate text to 8 bytes
    text_padded = String.pad_trailing(pdu.text, 8, <<0>>)
    text_bytes = binary_part(text_padded, 0, 8)

    payload =
      <<
        @proto_text::3,
        pdu.control::5,
        pdu.countdown::8,
        text_bytes::binary-size(8)
      >>

    append_crc(payload)
  end

  def encode(%BinMessage{} = pdu) do
    # Pad or truncate data to 8 bytes
    data_padded = pdu.data <> :binary.copy(<<0>>, 8)
    data_bytes = binary_part(data_padded, 0, 8)

    payload =
      <<
        @proto_binary::3,
        pdu.control::5,
        pdu.countdown::8,
        data_bytes::binary-size(8)
      >>

    append_crc(payload)
  end

  def encode(%MsgHdr{} = pdu) do
    payload =
      <<
        # Byte 0: proto(3)=util + subtype(3)=msg_hdr(000) + v(1) + m(1)
        @proto_util::3,
        @util_subtype_msg_hdr::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        # Byte 1: reserved (Figure G-28 shows an all-zero second octet)
        0::8,
        # Bytes 2-3: sender WALE address
        pdu.sender_addr::little-16,
        # Bytes 4-5: recipient WALE address
        pdu.recipient_addr::little-16,
        # Bytes 6-9: purpose (locally defined, 4 octets)
        binary_part(pdu.purpose <> <<0, 0, 0, 0>>, 0, 4)::binary-size(4)
      >>

    append_crc(payload)
  end

  def encode(%TodResponse{} = pdu) do
    payload =
      <<
        # Byte 0: proto(3)=util + subtype(3)=tod(101) + v(1) + m(1)
        @proto_util::3,
        @util_subtype_tod::3,
        bool_to_bit(pdu.voice)::1,
        bool_to_bit(pdu.more)::1,
        # Byte 1: ec(2) + sync_sign(2) + sync_tq(3) + reserved(1)
        pdu.equipment_class::2,
        pdu.sync_sign::2,
        pdu.sync_tq::3,
        0::1,
        # Bytes 2-3: caller_addr (the station that asked for TOD)
        pdu.caller_addr::little-16,
        # Bytes 4-5: responder_addr (us, serving the time)
        pdu.responder_addr::little-16,
        # Bytes 6-7: sync_mag (fine offset / uncertainty magnitude, ms)
        pdu.sync_mag::little-16,
        # Byte 8: coarse_min
        pdu.coarse_min::8,
        # Byte 9: coarse_sec
        pdu.coarse_sec::8
      >>

    append_crc(payload)
  end

  # -------------------------------------------------------------------
  # Transmission (multi-PDU) encode/parse
  # -------------------------------------------------------------------

  @doc """
  Encode a list of PDU structs into one transmission binary — the PDUs are
  concatenated in order. A 4G transmission is `[addressed carrier PDU][message
  PDUs...]`; the caller is responsible for setting the carrier PDU's `more`
  (M) flag to true when message PDUs follow.
  """
  @spec encode_stream([struct()]) :: binary()
  def encode_stream(pdus) when is_list(pdus) do
    pdus |> Enum.map(&encode/1) |> IO.iodata_to_binary()
  end

  @doc """
  Parse a received transmission binary into an ordered list of PDU structs.

  The burst is split into fixed 12-octet PDUs and each is decoded (CRC checked).
  Returns `{:ok, [pdu]}`, or `{:error, {:pdu, index, reason}}` on the first
  block that fails to decode, or `{:error, {:trailing_octets, n}}` if the burst
  length is not a whole number of PDUs.
  """
  @spec decode_stream(binary()) :: {:ok, [struct()]} | {:error, term()}
  def decode_stream(bin) when is_binary(bin), do: decode_stream(bin, 0, [])

  defp decode_stream(<<>>, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_stream(<<block::binary-size(@pdu_octets), rest::binary>>, index, acc) do
    case decode(block) do
      {:ok, pdu} -> decode_stream(rest, index + 1, [pdu | acc])
      {:error, reason} -> {:error, {:pdu, index, reason}}
    end
  end

  defp decode_stream(partial, _index, _acc) when byte_size(partial) > 0 do
    {:error, {:trailing_octets, byte_size(partial)}}
  end

  # -------------------------------------------------------------------
  # Decoding
  # -------------------------------------------------------------------

  @doc """
  Decode a 96-bit binary to a PDU struct.
  Returns {:ok, pdu} or {:error, reason}.
  """
  def decode(<<payload::binary-size(10), crc::little-16>>) do
    # Verify CRC
    computed_crc = compute_crc(payload)

    if computed_crc == crc do
      decode_payload(payload)
    else
      {:error, {:crc_mismatch, computed_crc, crc}}
    end
  end

  def decode(_), do: {:error, :invalid_length}

  defp decode_payload(<<@proto_lsu::3, @lsu_type_req::3, v::1, m::1, rest::binary>>) do
    <<
      ec::2,
      traf::6,
      caller::little-16,
      called::little-16,
      assigned::little-16,
      occupied::little-16
    >> = rest

    {:ok,
     %LsuReq{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       equipment_class: ec,
       traffic_type: traf,
       caller_addr: caller,
       called_addr: called,
       assigned_subchannels: assigned,
       occupied_subchannels: occupied
     }}
  end

  defp decode_payload(<<@proto_lsu::3, 1::3, v::1, m::1, rest::binary>>) do
    <<
      ec::2,
      snr::6,
      caller::little-16,
      called::little-16,
      tx::little-16,
      rx::little-16
    >> = rest

    {:ok,
     %LsuConf{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       equipment_class: ec,
       snr: snr,
       caller_addr: caller,
       called_addr: called,
       tx_subchannels: tx,
       rx_subchannels: rx
     }}
  end

  defp decode_payload(<<@proto_lsu::3, @lsu_type_term::3, v::1, m::1, rest::binary>>) do
    <<
      ec::2,
      reason::6,
      caller::little-16,
      called::little-16,
      _padding::32
    >> = rest

    {:ok,
     %LsuTerm{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       equipment_class: ec,
       reason: reason,
       caller_addr: caller,
       called_addr: called
     }}
  end

  defp decode_payload(<<@proto_text::3, control::5, countdown::8, text::binary-size(8)>>) do
    # Trim null bytes from text
    text_trimmed = String.trim_trailing(text, <<0>>)

    {:ok,
     %TxtMessage{
       control: control,
       countdown: countdown,
       text: text_trimmed
     }}
  end

  defp decode_payload(<<@proto_binary::3, control::5, countdown::8, data::binary-size(8)>>) do
    {:ok,
     %BinMessage{
       control: control,
       countdown: countdown,
       data: data
     }}
  end

  defp decode_payload(<<@proto_lsu::3, @lsu_type_status::3, v::1, m::1, rest::binary>>) do
    <<
      ec::2,
      status::6,
      caller::little-16,
      count::8,
      _reserved::8,
      assigned::little-16,
      _padding::16
    >> = rest

    {:ok,
     %LsuStatus{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       equipment_class: ec,
       status: status,
       caller_addr: caller,
       count: count,
       assigned_subchannels: assigned
     }}
  end

  defp decode_payload(<<@proto_util::3, @util_subtype_msg_hdr::3, v::1, m::1, rest::binary>>) do
    <<
      _reserved::8,
      sender::little-16,
      recipient::little-16,
      purpose::binary-size(4)
    >> = rest

    {:ok,
     %MsgHdr{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       sender_addr: sender,
       recipient_addr: recipient,
       purpose: purpose
     }}
  end

  defp decode_payload(<<@proto_util::3, @util_subtype_tod::3, v::1, m::1, rest::binary>>) do
    <<
      ec::2,
      sync_sign::2,
      sync_tq::3,
      _reserved::1,
      caller::little-16,
      responder::little-16,
      sync_mag::little-16,
      coarse_min::8,
      coarse_sec::8
    >> = rest

    {:ok,
     %TodResponse{
       voice: bit_to_bool(v),
       more: bit_to_bool(m),
       equipment_class: ec,
       sync_sign: sync_sign,
       sync_tq: sync_tq,
       sync_mag: sync_mag,
       caller_addr: caller,
       responder_addr: responder,
       coarse_min: coarse_min,
       coarse_sec: coarse_sec
     }}
  end

  defp decode_payload(_), do: {:error, :unknown_pdu_type}

  # -------------------------------------------------------------------
  # CRC-16
  # -------------------------------------------------------------------

  @doc """
  Compute CRC-16 per MIL-STD-188-141D.
  Polynomial: 0x9299, init: 0xFFFF, final XOR: 0xFFFF
  """
  def compute_crc(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce(@crc_init, &crc_byte/2)
    |> bxor(@crc_init)
  end

  defp crc_byte(byte, crc) do
    Enum.reduce(0..7, crc, fn i, acc ->
      bit = bxor(acc &&& 0x0001, byte >>> i &&& 0x0001)
      acc = acc >>> 1

      if bit == 1 do
        bxor(acc, @crc_poly)
      else
        acc
      end
    end)
  end

  defp append_crc(payload) do
    crc = compute_crc(payload)
    <<payload::binary, crc::little-16>>
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp bool_to_bit(true), do: 1
  defp bool_to_bit(false), do: 0

  defp bit_to_bool(1), do: true
  defp bit_to_bool(0), do: false
end
