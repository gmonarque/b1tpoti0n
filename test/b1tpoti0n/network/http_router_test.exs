defmodule B1tpoti0n.Network.HttpRouterTest do
  @moduledoc """
  Integration tests for HTTP tracker router endpoints.
  Tests full request/response cycle.
  """
  use B1tpoti0n.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias B1tpoti0n.Network.HttpRouter
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Persistence.Schemas.{Torrent, Whitelist, BannedIp}

  setup do
    Repo.delete_all(Torrent)
    Repo.delete_all(BannedIp)
    Manager.reload_passkeys()
    Manager.reload_whitelist()
    Manager.reload_banned_ips()

    Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
    Manager.reload_whitelist()

    :ok
  end

  defp call(conn) do
    HttpRouter.call(conn, HttpRouter.init([]))
  end

  defp create_torrent do
    info_hash = :crypto.strong_rand_bytes(20)
    {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})
    {info_hash, torrent}
  end

  defp create_user_with_passkey do
    user = create_user()
    Manager.reload_passkeys()
    user
  end

  defp encode_info_hash(info_hash) do
    info_hash
    |> :binary.bin_to_list()
    |> Enum.map(&URI.encode_www_form(<<&1>>))
    |> Enum.join()
  end

  describe "GET /:passkey/announce" do
    test "successful announce returns 200 with bencoded response" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      query =
        URI.encode_query(
          %{
            "info_hash" => info_hash,
            "peer_id" => peer_id,
            "port" => "6881",
            "uploaded" => "0",
            "downloaded" => "0",
            "left" => "1000000",
            "event" => "started",
            "compact" => "1"
          },
          :rfc3986
        )

      conn =
        conn(:get, "/#{user.passkey}/announce?#{query}")
        |> call()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert is_map(decoded)
      assert Map.has_key?(decoded, "interval")
    end

    test "announce with invalid passkey returns bencoded error" do
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)
      fake_passkey = String.duplicate("x", 32)

      query =
        URI.encode_query(
          %{
            "info_hash" => info_hash,
            "peer_id" => peer_id,
            "port" => "6881",
            "uploaded" => "0",
            "downloaded" => "0",
            "left" => "1000000"
          },
          :rfc3986
        )

      conn =
        conn(:get, "/#{fake_passkey}/announce?#{query}")
        |> call()

      assert conn.status == 200

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert Map.has_key?(decoded, "failure reason")
    end

    test "announce from banned IP returns ban message" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      B1tpoti0n.Admin.ban_ip("127.0.0.1", "Test ban")

      query =
        URI.encode_query(
          %{
            "info_hash" => info_hash,
            "peer_id" => peer_id,
            "port" => "6881",
            "uploaded" => "0",
            "downloaded" => "0",
            "left" => "1000000"
          },
          :rfc3986
        )

      conn =
        conn(:get, "/#{user.passkey}/announce?#{query}")
        |> call()

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert decoded["failure reason"] =~ "Not authorized"
    end
  end

  describe "GET /:passkey/scrape" do
    test "successful scrape returns torrent stats" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()

      encoded_hash = encode_info_hash(info_hash)
      query = "info_hash=#{encoded_hash}"

      conn =
        conn(:get, "/#{user.passkey}/scrape?#{query}")
        |> call()

      assert conn.status == 200

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert Map.has_key?(decoded, "files")
    end

    test "scrape without info_hash returns error" do
      user = create_user_with_passkey()

      conn =
        conn(:get, "/#{user.passkey}/scrape")
        |> call()

      assert conn.status == 200

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert Map.has_key?(decoded, "failure reason")
    end
  end

  describe "GET /health" do
    test "returns ok status" do
      conn = conn(:get, "/health") |> call()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /stats" do
    test "returns tracker statistics" do
      conn = conn(:get, "/stats") |> call()

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "cache")
      assert Map.has_key?(body, "active_transfers")
      assert Map.has_key?(body, "total_items")
      assert Map.has_key?(body, "throttle")
    end
  end

  describe "GET /metrics" do
    test "returns prometheus format" do
      conn = conn(:get, "/metrics") |> call()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
      assert conn.resp_body =~ "tracker_"
    end
  end

  describe "unknown routes" do
    test "returns 404 with bencoded error" do
      conn = conn(:get, "/unknown/path") |> call()

      assert conn.status == 404

      decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
      assert decoded["failure reason"] == "Not found"
    end
  end

  describe "X-Forwarded-For header handling" do
    test "uses forwarded IP when trust_x_forwarded_for is enabled" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      B1tpoti0n.Admin.ban_ip("10.0.0.1", "Test ban")

      old_val = Application.get_env(:b1tpoti0n, :trust_x_forwarded_for, false)
      Application.put_env(:b1tpoti0n, :trust_x_forwarded_for, true)

      try do
        query =
          URI.encode_query(
            %{
              "info_hash" => info_hash,
              "peer_id" => peer_id,
              "port" => "6881",
              "uploaded" => "0",
              "downloaded" => "0",
              "left" => "1000000"
            },
            :rfc3986
          )

        conn =
          conn(:get, "/#{user.passkey}/announce?#{query}")
          |> put_req_header("x-forwarded-for", "10.0.0.1, 192.168.1.1")
          |> call()

        decoded = B1tpoti0n.Core.Bencode.decode(conn.resp_body)
        assert decoded["failure reason"] =~ "Not authorized"
      after
        Application.put_env(:b1tpoti0n, :trust_x_forwarded_for, old_val)
      end
    end
  end
end
