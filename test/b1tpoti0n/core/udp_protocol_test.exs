defmodule B1tpoti0n.Core.UdpProtocolTest do
  @moduledoc """
  Tests for UDP tracker protocol encoding/decoding (BEP 15).
  """
  use ExUnit.Case, async: true

  alias B1tpoti0n.Core.UdpProtocol

  @protocol_id 0x41727101980

  describe "parse_request/1" do
    test "parses connect request" do
      transaction_id = 12345
      packet = <<@protocol_id::64, 0::32, transaction_id::32>>

      assert {:ok, :connect, %{transaction_id: ^transaction_id}} =
               UdpProtocol.parse_request(packet)
    end

    test "parses announce request" do
      connection_id = 123_456_789
      transaction_id = 12345
      info_hash = :crypto.strong_rand_bytes(20)
      peer_id = :crypto.strong_rand_bytes(20)

      packet =
        <<connection_id::64, 1::32, transaction_id::32, info_hash::binary-20, peer_id::binary-20,
          1000::64, 500::64, 200::64, 2::32, 0::32, 0::32, 50::signed-32, 6881::16>>

      assert {:ok, :announce, request} = UdpProtocol.parse_request(packet)
      assert request.connection_id == connection_id
      assert request.transaction_id == transaction_id
      assert request.info_hash == info_hash
      assert request.peer_id == peer_id
      assert request.downloaded == 1000
      assert request.left == 500
      assert request.uploaded == 200
      assert request.event == :started
      assert request.num_want == 50
      assert request.port == 6881
    end

    test "parses scrape request" do
      connection_id = 123_456_789
      transaction_id = 12345
      info_hash1 = :crypto.strong_rand_bytes(20)
      info_hash2 = :crypto.strong_rand_bytes(20)

      packet =
        <<connection_id::64, 2::32, transaction_id::32, info_hash1::binary-20,
          info_hash2::binary-20>>

      assert {:ok, :scrape, request} = UdpProtocol.parse_request(packet)
      assert request.connection_id == connection_id
      assert request.transaction_id == transaction_id
      assert length(request.info_hashes) == 2
      assert info_hash1 in request.info_hashes
      assert info_hash2 in request.info_hashes
    end

    test "handles negative num_want as default 50" do
      connection_id = 123_456_789
      transaction_id = 12345
      info_hash = :crypto.strong_rand_bytes(20)
      peer_id = :crypto.strong_rand_bytes(20)

      packet =
        <<connection_id::64, 1::32, transaction_id::32, info_hash::binary-20, peer_id::binary-20,
          0::64, 0::64, 0::64, 0::32, 0::32, 0::32, -1::signed-32, 6881::16>>

      assert {:ok, :announce, request} = UdpProtocol.parse_request(packet)
      assert request.num_want == 50
    end

    test "returns error for packet too short" do
      assert {:error, "Packet too short"} = UdpProtocol.parse_request(<<1, 2, 3>>)
    end

    test "returns error for invalid packet format" do
      # Wrong protocol_id
      assert {:error, _} = UdpProtocol.parse_request(<<1::64, 0::32, 12345::32>>)
    end

    test "returns error for unknown action" do
      assert {:error, "Unknown action: 99"} =
               UdpProtocol.parse_request(<<@protocol_id::64, 99::32, 12345::32>>)
    end
  end

  describe "encode_connect_response/2" do
    test "encodes connect response correctly" do
      transaction_id = 12345
      connection_id = 9_876_543_210

      response = UdpProtocol.encode_connect_response(transaction_id, connection_id)

      assert <<0::32, ^transaction_id::32, ^connection_id::64>> = response
    end
  end

  describe "encode_announce_response/5" do
    test "encodes announce response with IPv4 peers" do
      transaction_id = 12345
      interval = 1800
      leechers = 10
      seeders = 5
      peers = [{{192, 168, 1, 1}, 6881}, {{10, 0, 0, 1}, 6882}]

      response =
        UdpProtocol.encode_announce_response(transaction_id, interval, leechers, seeders, peers)

      # Action (1) + transaction_id + interval + leechers + seeders + peers
      assert <<1::32, ^transaction_id::32, ^interval::32, ^leechers::32, ^seeders::32, 192::8,
               168::8, 1::8, 1::8, 6881::16, 10::8, 0::8, 0::8, 1::8, 6882::16>> = response
    end

    test "encodes announce response with empty peers" do
      transaction_id = 12345
      response = UdpProtocol.encode_announce_response(transaction_id, 1800, 0, 0, [])

      assert <<1::32, ^transaction_id::32, 1800::32, 0::32, 0::32>> = response
    end
  end

  describe "encode_scrape_response/2" do
    test "encodes scrape response correctly" do
      transaction_id = 12345
      stats = [{100, 50, 25}, {200, 75, 30}]

      response = UdpProtocol.encode_scrape_response(transaction_id, stats)

      assert <<2::32, ^transaction_id::32, 100::32, 50::32, 25::32, 200::32, 75::32, 30::32>> =
               response
    end
  end

  describe "encode_error_response/2" do
    test "encodes error response correctly" do
      transaction_id = 12345
      message = "Rate limited"

      response = UdpProtocol.encode_error_response(transaction_id, message)

      assert <<3::32, ^transaction_id::32, "Rate limited">> = response
    end
  end

  describe "generate_connection_id/0" do
    test "generates random 64-bit connection ID" do
      id1 = UdpProtocol.generate_connection_id()
      id2 = UdpProtocol.generate_connection_id()

      assert is_integer(id1)
      assert is_integer(id2)
      assert id1 != id2
    end
  end

  describe "valid_connection_id?/2" do
    test "returns true for valid, non-expired connection" do
      connection_id = 12345
      expires_at = DateTime.add(DateTime.utc_now(), 60, :second)
      cache = %{connection_id => expires_at}

      assert UdpProtocol.valid_connection_id?(connection_id, cache) == true
    end

    test "returns false for expired connection" do
      connection_id = 12345
      expires_at = DateTime.add(DateTime.utc_now(), -60, :second)
      cache = %{connection_id => expires_at}

      assert UdpProtocol.valid_connection_id?(connection_id, cache) == false
    end

    test "returns false for unknown connection" do
      cache = %{}
      assert UdpProtocol.valid_connection_id?(12345, cache) == false
    end
  end

  describe "event_to_string/1" do
    test "converts events correctly" do
      assert UdpProtocol.event_to_string(:none) == nil
      assert UdpProtocol.event_to_string(:completed) == "completed"
      assert UdpProtocol.event_to_string(:started) == "started"
      assert UdpProtocol.event_to_string(:stopped) == "stopped"
    end
  end

  describe "int_to_ip/1" do
    test "converts integer to IP tuple" do
      # 192.168.1.1 = 192*2^24 + 168*2^16 + 1*2^8 + 1
      ip_int = 192 * 16_777_216 + 168 * 65_536 + 1 * 256 + 1
      assert UdpProtocol.int_to_ip(ip_int) == {192, 168, 1, 1}
    end
  end
end
