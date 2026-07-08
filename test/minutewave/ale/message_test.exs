defmodule Minutewave.ALE.MessageTest do
  use ExUnit.Case, async: true

  alias Minutewave.ALE.Message
  alias Minutewave.ALE.PDU

  import Bitwise

  # Encode each PDU to wire bytes and decode it back, mimicking a real
  # transmission through the single-PDU codec (incl. NUL trimming for text).
  defp round_trip(pdus) do
    Enum.map(pdus, fn pdu ->
      {:ok, decoded} = pdu |> PDU.encode() |> PDU.decode()
      decoded
    end)
  end

  defp popcount(x), do: Enum.reduce(0..7, 0, fn i, a -> a + (x >>> i &&& 1) end)

  describe "control field (Figure G-31)" do
    test "pack/unpack round-trips over all combinations" do
      for padding <- 0..7, som <- [true, false], eom <- [true, false] do
        c = Message.pack_control(padding, som, eom)
        assert c in 0..31
        assert Message.unpack_control(c) == %{padding: padding, som: som, eom: eom}
      end
    end

    test "bit layout is [Padding:3][SOM:1][EOM:1]" do
      assert Message.pack_control(0, true, true) == 0b00011
      assert Message.pack_control(7, false, false) == 0b11100
      assert Message.pack_control(5, true, false) == 0b10110
    end
  end

  describe "ASCII odd-parity coding (G.5.6.3)" do
    test "every coded octet has odd parity" do
      for c <- 0..127 do
        octet = Message.put_parity(c)
        assert rem(popcount(octet), 2) == 1
        assert (octet &&& 0x7F) == c
      end
    end

    test "check_parity strips the char and validates parity" do
      octet = Message.put_parity(?A)
      assert Message.check_parity(octet) == {?A, true}
      # flip the parity bit -> now even parity -> invalid
      assert {?A, false} = Message.check_parity(bxor(octet, 0x80))
    end
  end

  describe "fragment_text" do
    test "single char -> one PDU, SOM+EOM, countdown 0, padding 7" do
      {:ok, [pdu]} = Message.fragment_text("A")
      assert %{padding: 7, som: true, eom: true} = Message.unpack_control(pdu.control)
      assert pdu.countdown == 0
    end

    test "exactly 8 octets -> one PDU, padding 0" do
      {:ok, [pdu]} = Message.fragment_text("ABCDEFGH")
      assert %{padding: 0, som: true, eom: true} = Message.unpack_control(pdu.control)
      assert pdu.countdown == 0
    end

    test "9 octets -> two PDUs with correct framing" do
      {:ok, [p0, p1]} = Message.fragment_text("ABCDEFGHI")
      assert %{padding: 0, som: true, eom: false} = Message.unpack_control(p0.control)
      assert p0.countdown == 1
      assert %{padding: 7, som: false, eom: true} = Message.unpack_control(p1.control)
      assert p1.countdown == 0
    end

    test "rejects empty, non-ASCII, and over-length" do
      assert {:error, :empty_message} = Message.fragment_text("")
      assert {:error, :non_ascii} = Message.fragment_text(<<"hi", 0xFF>>)
      big = :binary.copy("x", 2049)
      assert {:error, {:too_long, 2049, 2048}} = Message.fragment_text(big)
    end
  end

  describe "text round-trip (fragment -> wire -> reassemble)" do
    for {label, msg} <- [
          {"one char", "K"},
          {"exactly 8", "ABCDEFGH"},
          {"non-multiple", "Hello, MinuteModem!"},
          {"multi-PDU", String.duplicate("The quick brown fox. ", 20)},
          {"max length", :binary.copy("Z", 2048)}
        ] do
      test "round-trips byte-identical: #{label}" do
        msg = unquote(msg)
        {:ok, pdus} = Message.fragment_text(msg)
        decoded = round_trip(pdus)
        {:ok, result} = Message.reassemble_text(decoded)
        assert result.text == msg
        assert result.parity_errors == 0
        assert result.pdu_count == length(pdus)
      end
    end

    test "detects a corrupted-parity octet on reassembly" do
      {:ok, [pdu]} = Message.fragment_text("HELLO")
      # Corrupt the parity of the first text octet (flip its MSB).
      <<first, rest::binary>> = pdu.text
      bad = %{pdu | text: <<bxor(first, 0x80), rest::binary>>}
      {:ok, result} = Message.reassemble_text([bad])
      assert result.parity_errors == 1
      assert result.error_positions == [0]
    end
  end

  describe "binary round-trip (preserves embedded zero octets)" do
    for {label, data} <- [
          {"single octet", <<0x00>>},
          {"with embedded nulls", <<1, 0, 2, 0, 0, 3>>},
          {"exactly 8", <<0, 1, 2, 3, 4, 5, 6, 7>>},
          {"non-multiple", <<9, 8, 7, 6, 5, 4, 3, 2, 1>>},
          {"max length", :binary.copy(<<0xA5>>, 2048)}
        ] do
      test "round-trips byte-identical: #{label}" do
        data = unquote(data)
        {:ok, pdus} = Message.fragment_binary(data)
        decoded = round_trip(pdus)
        assert {:ok, ^data} = Message.reassemble_binary(decoded)
      end
    end
  end

  describe "Message Header PDU (Figure G-28) + TOD subtype fix" do
    test "MsgHdr leading byte is 0x61 (011 000 V=0 M=1)" do
      hdr = %PDU.MsgHdr{sender_addr: 0x1234, recipient_addr: 0x5678}
      <<first, _rest::binary>> = PDU.encode(hdr)
      assert first == 0x61
    end

    test "MsgHdr round-trips (addrs + purpose)" do
      hdr = %PDU.MsgHdr{
        sender_addr: 0xABCD,
        recipient_addr: 0x0F0F,
        purpose: <<1, 2, 3, 4>>
      }

      {:ok, decoded} = hdr |> PDU.encode() |> PDU.decode()
      assert %PDU.MsgHdr{} = decoded
      assert decoded.sender_addr == 0xABCD
      assert decoded.recipient_addr == 0x0F0F
      assert decoded.purpose == <<1, 2, 3, 4>>
      assert decoded.more == true
    end

    test "MsgHdr and TOD Response no longer collide (distinct subtypes)" do
      hdr = %PDU.MsgHdr{sender_addr: 1, recipient_addr: 2}
      tod = %PDU.TodResponse{caller_addr: 1, responder_addr: 2, coarse_min: 30, coarse_sec: 15}

      {:ok, d_hdr} = hdr |> PDU.encode() |> PDU.decode()
      {:ok, d_tod} = tod |> PDU.encode() |> PDU.decode()

      assert %PDU.MsgHdr{} = d_hdr
      assert %PDU.TodResponse{} = d_tod
      # TOD now carries subtype 101 in its second nibble
      <<_p::3, subtype::3, _v::1, _m::1, _::binary>> = PDU.encode(tod)
      assert subtype == 0b101
    end

    test "TOD Response still round-trips after the subtype correction" do
      tod = %PDU.TodResponse{
        caller_addr: 0x1111,
        responder_addr: 0x2222,
        sync_mag: 42,
        coarse_min: 12,
        coarse_sec: 34
      }

      {:ok, decoded} = tod |> PDU.encode() |> PDU.decode()
      assert decoded.caller_addr == 0x1111
      assert decoded.responder_addr == 0x2222
      assert decoded.sync_mag == 42
      assert decoded.coarse_min == 12
      assert decoded.coarse_sec == 34
    end
  end

  describe "reassembly framing validation" do
    test "rejects missing SOM / missing EOM / bad countdown" do
      {:ok, [p0, p1]} = Message.fragment_text("ABCDEFGHI")

      # Clear SOM on the first PDU.
      no_som = %{p0 | control: Message.pack_control(0, false, false)}
      assert {:error, :missing_som} = Message.reassemble_text([no_som, p1])

      # Clear EOM on the last PDU.
      no_eom = %{p1 | control: Message.pack_control(7, false, false)}
      assert {:error, :missing_eom} = Message.reassemble_text([p0, no_eom])

      # Corrupt the countdown sequence.
      bad_cd = %{p1 | countdown: 5}
      assert {:error, {:bad_countdown, _}} = Message.reassemble_text([p0, bad_cd])
    end
  end

  describe "transmission (multi-PDU) codec + end-to-end" do
    test "piggyback: [LSU_Req M=1][text PDUs] round-trips and reassembles" do
      carrier = %PDU.LsuReq{caller_addr: 0x11, called_addr: 0x22, more: true}
      {:ok, msg_pdus} = Message.fragment_text("Hello over ALE")
      tx = PDU.encode_stream([carrier | msg_pdus])

      {:ok, [d_carrier | d_msgs]} = PDU.decode_stream(tx)
      assert %PDU.LsuReq{caller_addr: 0x11, called_addr: 0x22, more: true} = d_carrier
      {:ok, result} = Message.reassemble_text(d_msgs)
      assert result.text == "Hello over ALE"
    end

    test "stand-alone: [MsgHdr][text PDUs] end to end" do
      hdr = %PDU.MsgHdr{sender_addr: 0xAAAA, recipient_addr: 0xBBBB}
      body = "standalone message body that spans several PDUs!"
      {:ok, msg_pdus} = Message.fragment_text(body)
      tx = PDU.encode_stream([hdr | msg_pdus])

      {:ok, [d_hdr | d_msgs]} = PDU.decode_stream(tx)
      assert %PDU.MsgHdr{sender_addr: 0xAAAA, recipient_addr: 0xBBBB} = d_hdr
      {:ok, result} = Message.reassemble_text(d_msgs)
      assert result.text == body
    end

    test "rejects a burst that is not a whole number of PDUs" do
      assert {:error, {:trailing_octets, 3}} = PDU.decode_stream(<<1, 2, 3>>)
    end

    test "reports the index of a CRC-failed PDU" do
      p0 = PDU.encode(%PDU.MsgHdr{sender_addr: 1, recipient_addr: 2})
      p1 = PDU.encode(%PDU.MsgHdr{sender_addr: 3, recipient_addr: 4})
      <<head::binary-size(11), crc_last>> = p1
      corrupt = <<head::binary, bxor(crc_last, 0xFF)>>
      assert {:error, {:pdu, 1, {:crc_mismatch, _, _}}} = PDU.decode_stream(p0 <> corrupt)
    end
  end
end
