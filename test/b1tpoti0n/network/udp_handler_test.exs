defmodule B1tpoti0n.Network.UdpHandlerTest do
  @moduledoc """
  Tests for UDP tracker protocol handler (BEP 15).
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Network.UdpHandler
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Persistence.Schemas.{Torrent, Whitelist, BannedIp}

  # UDP protocol constants
  @protocol_id 0x41727101980
  @action_connect 0
  @action_announce 1
  @action_scrape 2

  setup do
    Repo.delete_all(Torrent)
    Repo.delete_all(BannedIp)
    Repo.delete_all(Whitelist)
    Manager.reload_whitelist()
    Manager.reload_banned_ips()

    # Whitelist Transmission client
    Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
    Manager.reload_whitelist()

    :ok
  end

  defp create_torrent do
    info_hash = :crypto.strong_rand_bytes(20)
    {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})
    {info_hash, torrent}
  end

  # Build a connect request packet (16 bytes)
  defp build_connect_request(transaction_id) do
    <<@protocol_id::64, @action_connect::32, transaction_id::32>>
  end

  # Build an announce request packet
  defp build_announce_request(
         connection_id,
         transaction_id,
         info_hash,
         peer_id,
         downloaded,
         left,
         uploaded,
         event,
         port
       ) do
    # Event: 0=none, 1=completed, 2=started, 3=stopped
    <<connection_id::64, @action_announce::32, transaction_id::32, info_hash::binary-20,
      peer_id::binary-20, downloaded::64, left::64, uploaded::64, event::32, 0::32, 0::32,
      -1::signed-32, port::16>>
  end

  # Build a scrape request packet
  defp build_scrape_request(connection_id, transaction_id, info_hashes) do
    hashes_binary = Enum.reduce(info_hashes, <<>>, fn h, acc -> acc <> h end)
    <<connection_id::64, @action_scrape::32, transaction_id::32, hashes_binary::binary>>
  end

  describe "handle_packet/2 - connect request" do
    test "returns connect response for valid request" do
      # Build connect request
      transaction_id = :rand.uniform(0xFFFFFFFF)
      request = build_connect_request(transaction_id)

      response = UdpHandler.handle_packet(request, {127, 0, 0, 1})

      assert is_binary(response)
      # Connect response size
      assert byte_size(response) == 16

      # Parse response
      <<action::32, recv_transaction_id::32, connection_id::64>> = response
      # Connect action
      assert action == 0
      assert recv_transaction_id == transaction_id
      assert connection_id != 0
    end
  end

  describe "handle_packet/2 - announce request" do
    test "returns announce response for valid request" do
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      # First get a connection_id
      transaction_id = :rand.uniform(0xFFFFFFFF)
      connect_req = build_connect_request(transaction_id)
      connect_resp = UdpHandler.handle_packet(connect_req, {127, 0, 0, 1})
      <<_::32, _::32, connection_id::64>> = connect_resp

      # Build announce request
      announce_transaction_id = :rand.uniform(0xFFFFFFFF)

      announce_req =
        build_announce_request(
          connection_id,
          announce_transaction_id,
          info_hash,
          peer_id,
          # downloaded
          0,
          # left
          1000,
          # uploaded
          0,
          # event: started
          2,
          # port
          6881
        )

      response = UdpHandler.handle_packet(announce_req, {127, 0, 0, 1})

      assert is_binary(response)
      # Minimum announce response size
      assert byte_size(response) >= 20

      # Parse response header
      <<action::32, recv_transaction_id::32, _interval::32, _leechers::32, _seeders::32,
        _rest::binary>> = response

      # Announce action
      assert action == 1
      assert recv_transaction_id == announce_transaction_id
    end

    test "returns error for invalid connection_id" do
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      # Use invalid connection_id
      invalid_connection_id = 12_345_678

      announce_transaction_id = :rand.uniform(0xFFFFFFFF)

      announce_req =
        build_announce_request(
          invalid_connection_id,
          announce_transaction_id,
          info_hash,
          peer_id,
          0,
          1000,
          0,
          2,
          6881
        )

      response = UdpHandler.handle_packet(announce_req, {127, 0, 0, 1})

      # Should return error response
      <<action::32, recv_transaction_id::32, _message::binary>> = response
      # Error action
      assert action == 3
      assert recv_transaction_id == announce_transaction_id
    end

    test "returns error for non-whitelisted client" do
      {info_hash, _torrent} = create_torrent()
      # Non-whitelisted
      peer_id = "-XX0000-" <> :crypto.strong_rand_bytes(12)

      # Get valid connection_id
      connect_req = build_connect_request(:rand.uniform(0xFFFFFFFF))
      <<_::32, _::32, connection_id::64>> = UdpHandler.handle_packet(connect_req, {127, 0, 0, 1})

      # Announce with non-whitelisted client
      announce_transaction_id = :rand.uniform(0xFFFFFFFF)

      announce_req =
        build_announce_request(
          connection_id,
          announce_transaction_id,
          info_hash,
          peer_id,
          0,
          1000,
          0,
          2,
          6881
        )

      response = UdpHandler.handle_packet(announce_req, {127, 0, 0, 1})

      <<action::32, _::binary>> = response
      # Error action
      assert action == 3
    end
  end

  describe "handle_packet/2 - scrape request" do
    test "returns scrape response for valid request" do
      {info_hash, _torrent} = create_torrent()

      # Get valid connection_id
      connect_req = build_connect_request(:rand.uniform(0xFFFFFFFF))
      <<_::32, _::32, connection_id::64>> = UdpHandler.handle_packet(connect_req, {127, 0, 0, 1})

      # Build scrape request
      scrape_transaction_id = :rand.uniform(0xFFFFFFFF)
      scrape_req = build_scrape_request(connection_id, scrape_transaction_id, [info_hash])

      response = UdpHandler.handle_packet(scrape_req, {127, 0, 0, 1})

      assert is_binary(response)
      # Minimum scrape response
      assert byte_size(response) >= 8

      # Parse response
      <<action::32, recv_transaction_id::32, _rest::binary>> = response
      # Scrape action
      assert action == 2
      assert recv_transaction_id == scrape_transaction_id
    end
  end

  describe "handle_packet/2 - banned IP" do
    test "returns nil for banned IP" do
      # Ban the IP
      B1tpoti0n.Admin.ban_ip("127.0.0.1", "Test ban")

      # Try connect
      transaction_id = :rand.uniform(0xFFFFFFFF)
      request = build_connect_request(transaction_id)

      response = UdpHandler.handle_packet(request, {127, 0, 0, 1})

      assert is_nil(response)
    end
  end

  describe "handle_packet/2 - malformed requests" do
    test "returns nil for too short packet" do
      response = UdpHandler.handle_packet(<<1, 2, 3>>, {127, 0, 0, 1})
      assert is_nil(response)
    end

    test "returns nil for invalid action" do
      # Build a packet with invalid action
      # action 99 doesn't exist
      invalid_packet = <<0xFFFFFFFF::64, 99::32, 12345::32>>
      response = UdpHandler.handle_packet(invalid_packet, {127, 0, 0, 1})
      assert is_nil(response)
    end
  end
end
