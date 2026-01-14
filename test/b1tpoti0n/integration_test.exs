defmodule B1tpoti0n.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the tracker.
  Tests complete request lifecycles.
  """
  use B1tpoti0n.DataCase, async: false
  import Plug.Test

  alias B1tpoti0n.Network.HttpRouter
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Stats.{Buffer, Collector}
  alias B1tpoti0n.Persistence.Schemas.{Torrent, Whitelist, User}
  alias B1tpoti0n.Core.Bencode

  setup do
    Repo.delete_all(Torrent)
    Repo.delete_all(Whitelist)
    Repo.delete_all(B1tpoti0n.Persistence.Schemas.BannedIp)
    Manager.reload_passkeys()
    Manager.reload_whitelist()
    Manager.reload_banned_ips()
    Buffer.flush()

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

  defp build_announce_query(info_hash, peer_id, opts \\ []) do
    base = %{
      "info_hash" => info_hash,
      "peer_id" => peer_id,
      "port" => to_string(Keyword.get(opts, :port, 6881)),
      "uploaded" => to_string(Keyword.get(opts, :uploaded, 0)),
      "downloaded" => to_string(Keyword.get(opts, :downloaded, 0)),
      "left" => to_string(Keyword.get(opts, :left, 1_000_000)),
      "event" => Keyword.get(opts, :event, "started"),
      "compact" => "1"
    }

    URI.encode_query(base, :rfc3986)
  end

  describe "full announce lifecycle" do
    test "peer joins as leecher" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      query = build_announce_query(info_hash, peer_id, event: "started", left: 1_000_000)
      conn = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()

      assert conn.status == 200
      decoded = Bencode.decode(conn.resp_body)
      assert decoded["interval"] > 0
      assert decoded["incomplete"] == 1
      assert is_binary(decoded["tracker id"])
    end

    test "peer joins as seeder and completes records snatch" do
      user = create_user_with_passkey()
      {info_hash, torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      query =
        build_announce_query(info_hash, peer_id,
          event: "completed",
          left: 0,
          downloaded: 1_000_000
        )

      conn = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()

      assert conn.status == 200
      decoded = Bencode.decode(conn.resp_body)
      assert decoded["complete"] == 1

      snatch = B1tpoti0n.Snatches.get_snatch(user.id, torrent.id)
      assert snatch != nil
    end

    test "multiple peers from different users see each other" do
      user1 = create_user_with_passkey()
      user2 = create_user_with_passkey()
      user3 = create_user_with_passkey()

      {info_hash, _torrent} = create_torrent()

      peer_id1 = "-TR3000-" <> :crypto.strong_rand_bytes(12)
      peer_id2 = "-TR3001-" <> :crypto.strong_rand_bytes(12)
      peer_id3 = "-TR3002-" <> :crypto.strong_rand_bytes(12)

      query = build_announce_query(info_hash, peer_id1, event: "started", left: 0, port: 6881)
      conn1 = conn(:get, "/#{user1.passkey}/announce?#{query}") |> call()
      decoded1 = Bencode.decode(conn1.resp_body)

      refute Map.has_key?(decoded1, "failure reason"),
             "First announce should succeed: #{inspect(decoded1)}"

      query =
        build_announce_query(info_hash, peer_id2, event: "started", left: 1_000_000, port: 6882)

      conn2 = conn(:get, "/#{user2.passkey}/announce?#{query}") |> call()
      decoded2 = Bencode.decode(conn2.resp_body)

      refute Map.has_key?(decoded2, "failure reason"),
             "Second announce should succeed: #{inspect(decoded2)}"

      assert decoded2["complete"] == 1
      assert decoded2["incomplete"] == 1

      query =
        build_announce_query(info_hash, peer_id3, event: "started", left: 1_000_000, port: 6883)

      conn3 = conn(:get, "/#{user3.passkey}/announce?#{query}") |> call()
      decoded3 = Bencode.decode(conn3.resp_body)

      refute Map.has_key?(decoded3, "failure reason"),
             "Third announce should succeed: #{inspect(decoded3)}"

      assert decoded3["complete"] == 1
      assert decoded3["incomplete"] == 2
    end
  end

  describe "stats recording and flushing" do
    test "stats are recorded to buffer and flushed to database" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      initial_uploaded = user.uploaded

      query = build_announce_query(info_hash, peer_id, event: "started", uploaded: 0)
      conn1 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded1 = Bencode.decode(conn1.resp_body)
      refute Map.has_key?(decoded1, "failure reason"), "First announce should succeed"
      tracker_key = decoded1["tracker id"]

      query = build_announce_query(info_hash, peer_id, event: "", uploaded: 1_000_000)
      query = query <> "&key=#{tracker_key}"
      conn2 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded2 = Bencode.decode(conn2.resp_body)
      refute Map.has_key?(decoded2, "failure reason"), "Second announce should succeed"

      Collector.force_flush()

      updated_user = Repo.get!(User, user.id)
      assert updated_user.uploaded > initial_uploaded
    end
  end

  describe "multiplier application" do
    test "upload multiplier increases upload credit" do
      user = create_user_with_passkey()
      {info_hash, torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      B1tpoti0n.Torrents.set_multipliers(torrent.id, 2.0, 1.0)

      query = build_announce_query(info_hash, peer_id, event: "started", uploaded: 0)
      conn1 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded1 = Bencode.decode(conn1.resp_body)
      refute Map.has_key?(decoded1, "failure reason"), "First announce should succeed"
      tracker_key = decoded1["tracker id"]

      query = build_announce_query(info_hash, peer_id, event: "", uploaded: 1_000_000)
      query = query <> "&key=#{tracker_key}"
      conn2 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded2 = Bencode.decode(conn2.resp_body)
      refute Map.has_key?(decoded2, "failure reason"), "Second announce should succeed"

      Collector.force_flush()
      updated_user = Repo.get!(User, user.id)

      assert updated_user.uploaded == 2_000_000
    end

    test "freeleech zeros download charge" do
      user = create_user_with_passkey()
      {info_hash, torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

      B1tpoti0n.Torrents.set_freeleech(torrent.id, true)

      query = build_announce_query(info_hash, peer_id, event: "started", downloaded: 0)
      conn1 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded1 = Bencode.decode(conn1.resp_body)
      refute Map.has_key?(decoded1, "failure reason"), "First announce should succeed"
      tracker_key = decoded1["tracker id"]

      query = build_announce_query(info_hash, peer_id, event: "", downloaded: 1_000_000, left: 0)
      query = query <> "&key=#{tracker_key}"
      conn2 = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()
      decoded2 = Bencode.decode(conn2.resp_body)
      refute Map.has_key?(decoded2, "failure reason"), "Second announce should succeed"

      Collector.force_flush()
      updated_user = Repo.get!(User, user.id)

      assert updated_user.downloaded == 0
    end
  end

  describe "scrape lifecycle" do
    test "scrape returns accurate stats" do
      user1 = create_user_with_passkey()
      user2 = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()

      peer_id1 = "-TR3000-" <> :crypto.strong_rand_bytes(12)
      peer_id2 = "-TR3001-" <> :crypto.strong_rand_bytes(12)

      query = build_announce_query(info_hash, peer_id1, event: "started", left: 0, port: 6881)
      conn1 = conn(:get, "/#{user1.passkey}/announce?#{query}") |> call()
      decoded1 = Bencode.decode(conn1.resp_body)
      refute Map.has_key?(decoded1, "failure reason"), "Seeder announce should succeed"

      query =
        build_announce_query(info_hash, peer_id2, event: "started", left: 1_000_000, port: 6882)

      conn2 = conn(:get, "/#{user2.passkey}/announce?#{query}") |> call()
      decoded2 = Bencode.decode(conn2.resp_body)
      refute Map.has_key?(decoded2, "failure reason"), "Leecher announce should succeed"

      encoded_hash =
        info_hash
        |> :binary.bin_to_list()
        |> Enum.map(&URI.encode_www_form(<<&1>>))
        |> Enum.join()

      conn = conn(:get, "/#{user1.passkey}/scrape?info_hash=#{encoded_hash}") |> call()

      assert conn.status == 200
      decoded = Bencode.decode(conn.resp_body)

      torrent_info = decoded["files"][info_hash]
      assert torrent_info["complete"] == 1
      assert torrent_info["incomplete"] == 1
    end
  end

  describe "error handling" do
    test "invalid passkey is rejected" do
      {info_hash, _torrent} = create_torrent()
      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)
      fake_passkey = String.duplicate("x", 32)

      query = build_announce_query(info_hash, peer_id)
      conn = conn(:get, "/#{fake_passkey}/announce?#{query}") |> call()

      decoded = Bencode.decode(conn.resp_body)
      assert Map.has_key?(decoded, "failure reason")
      assert decoded["failure reason"] =~ "passkey"
    end

    test "non-whitelisted client is rejected" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      peer_id = "-XX0000-" <> :crypto.strong_rand_bytes(12)

      query = build_announce_query(info_hash, peer_id)
      conn = conn(:get, "/#{user.passkey}/announce?#{query}") |> call()

      decoded = Bencode.decode(conn.resp_body)
      assert decoded["failure reason"] =~ "Not authorized"
    end

    test "missing required parameters are rejected" do
      user = create_user_with_passkey()

      conn =
        conn(:get, "/#{user.passkey}/announce?port=6881&uploaded=0&downloaded=0&left=0") |> call()

      decoded = Bencode.decode(conn.resp_body)
      assert Map.has_key?(decoded, "failure reason")
    end
  end
end
