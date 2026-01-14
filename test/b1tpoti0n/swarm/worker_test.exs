defmodule B1tpoti0n.Swarm.WorkerTest do
  @moduledoc """
  Tests for Swarm.Worker GenServer - per-torrent peer management.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Swarm.Worker
  alias B1tpoti0n.Persistence.Schemas.Torrent

  setup do
    # Start the Registry if not already running (needed for Worker via_tuple)
    case Registry.start_link(keys: :unique, name: B1tpoti0n.Swarm.Registry) do
      {:ok, registry_pid} ->
        on_exit(fn ->
          try do
            if Process.alive?(registry_pid), do: GenServer.stop(registry_pid, :normal, 100)
          catch
            :exit, _ -> :ok
          end
        end)

      {:error, {:already_started, _}} ->
        :ok
    end

    # Create a torrent
    info_hash = :crypto.strong_rand_bytes(20)
    {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})

    # Start a worker
    {:ok, pid} = Worker.start_link({info_hash, torrent.id})

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, info_hash: info_hash, torrent: torrent, worker: pid}
  end

  defp peer_data(opts \\ []) do
    %{
      user_id: Keyword.get(opts, :user_id, 1),
      ip: Keyword.get(opts, :ip, {192, 168, 1, Enum.random(1..254)}),
      port: Keyword.get(opts, :port, 6881),
      left: Keyword.get(opts, :left, 1000),
      peer_id: Keyword.get(opts, :peer_id, "-TR3000-" <> :crypto.strong_rand_bytes(12)),
      event: Keyword.get(opts, :event, :started),
      uploaded: Keyword.get(opts, :uploaded, 0),
      downloaded: Keyword.get(opts, :downloaded, 0),
      key: Keyword.get(opts, :key)
    }
  end

  describe "announce/3" do
    test "registers new peer as leecher", %{worker: worker} do
      peer = peer_data(left: 1000)

      {seeders, leechers, _peers, stats_delta, announce_key} = Worker.announce(worker, peer, 50)

      assert seeders == 0
      assert leechers == 1
      assert is_binary(announce_key)
      assert stats_delta.uploaded == 0
      assert stats_delta.downloaded == 0
    end

    test "registers new peer as seeder when left=0", %{worker: worker} do
      peer = peer_data(left: 0)

      {seeders, leechers, _peers, _stats_delta, _key} = Worker.announce(worker, peer, 50)

      assert seeders == 1
      assert leechers == 0
    end

    test "returns list of other peers", %{worker: worker} do
      # Register 3 peers
      peer1 = peer_data(ip: {192, 168, 1, 1}, port: 6881, user_id: 1)
      peer2 = peer_data(ip: {192, 168, 1, 2}, port: 6882, user_id: 2)
      peer3 = peer_data(ip: {192, 168, 1, 3}, port: 6883, user_id: 3)

      Worker.announce(worker, peer1, 50)
      Worker.announce(worker, peer2, 50)

      {_, _, peers, _, _} = Worker.announce(worker, peer3, 50)

      # Peer3 should see peer1 and peer2
      assert length(peers) == 2
    end

    test "excludes requesting peer from peer list", %{worker: worker} do
      peer1 = peer_data(ip: {192, 168, 1, 1}, port: 6881, user_id: 1)
      peer2 = peer_data(ip: {192, 168, 1, 2}, port: 6882, user_id: 2)

      {_, _, _, _, key1} = Worker.announce(worker, peer1, 50)
      Worker.announce(worker, peer2, 50)

      # Second announce from peer1 with key
      peer1_with_key = %{peer1 | key: key1, event: :none}
      {_, _, peers, _, _} = Worker.announce(worker, peer1_with_key, 50)

      # Should only see peer2, not itself
      assert length(peers) == 1
      peer_ips = Enum.map(peers, & &1.ip)
      refute {192, 168, 1, 1} in peer_ips
    end

    test "respects num_want limit", %{worker: worker} do
      # Register 10 peers
      Enum.each(1..10, fn i ->
        peer = peer_data(ip: {192, 168, 1, i}, port: 6880 + i, user_id: i)
        Worker.announce(worker, peer, 50)
      end)

      # New peer asks for only 3
      new_peer = peer_data(ip: {10, 0, 0, 1}, user_id: 100)
      {_, _, peers, _, _} = Worker.announce(worker, new_peer, 3)

      assert length(peers) == 3
    end

    test "calculates upload/download delta correctly", %{worker: worker} do
      peer = peer_data(uploaded: 1000, downloaded: 500)

      # First announce
      {_, _, _, stats_delta1, key} = Worker.announce(worker, peer, 50)
      assert stats_delta1.uploaded == 1000
      assert stats_delta1.downloaded == 500

      # Second announce with more stats
      peer2 = %{peer | uploaded: 5000, downloaded: 2500, key: key, event: :none}
      {_, _, _, stats_delta2, _} = Worker.announce(worker, peer2, 50)

      # Delta should be the difference
      assert stats_delta2.uploaded == 4000
      assert stats_delta2.downloaded == 2000
    end

    test "handles client restart (stats reset)", %{worker: worker} do
      peer = peer_data(uploaded: 10000, downloaded: 5000)

      # First announce
      {_, _, _, _, key} = Worker.announce(worker, peer, 50)

      # Client restart: lower stats than before
      peer2 = %{peer | uploaded: 100, downloaded: 50, key: key, event: :none}
      {_, _, _, stats_delta, _} = Worker.announce(worker, peer2, 50)

      # Should clamp to 0 (not negative)
      assert stats_delta.uploaded == 0
      assert stats_delta.downloaded == 0
    end

    test "removes peer on stopped event", %{worker: worker} do
      peer = peer_data()

      # Register peer
      {_, leechers1, _, _, key} = Worker.announce(worker, peer, 50)
      assert leechers1 == 1

      # Stop event with key
      stopped_peer = %{peer | event: :stopped, key: key}
      {_, leechers2, _, _, _} = Worker.announce(worker, stopped_peer, 50)
      assert leechers2 == 0
    end

    test "tracks completed event", %{worker: worker} do
      peer = peer_data(left: 1000)

      # Start as leecher
      {_, _, _, _, key} = Worker.announce(worker, peer, 50)

      # Complete download with key
      completed_peer = %{peer | event: :completed, left: 0, key: key}
      {seeders, leechers, _, _, _} = Worker.announce(worker, completed_peer, 50)

      # Should now be seeder
      assert seeders == 1
      assert leechers == 0

      # Verify completed count increased
      {_, completed, _} = Worker.get_stats(worker)
      assert completed == 1
    end

    test "generates announce key for new peer", %{worker: worker} do
      peer = peer_data()

      {_, _, _, _, announce_key} = Worker.announce(worker, peer, 50)

      assert is_binary(announce_key)
      # 8 bytes hex encoded
      assert byte_size(announce_key) == 16
    end

    test "validates announce key for returning peer", %{worker: worker} do
      # Enable announce key enforcement for this test
      old_val = Application.get_env(:b1tpoti0n, :enforce_announce_key, false)
      Application.put_env(:b1tpoti0n, :enforce_announce_key, true)

      try do
        peer = peer_data()

        # First announce gets a key
        {_, _, _, _, announce_key} = Worker.announce(worker, peer, 50)

        # Return with correct key
        peer_with_key = %{peer | key: announce_key, event: :none}
        assert {_, _, _, _, ^announce_key} = Worker.announce(worker, peer_with_key, 50)

        # Return with wrong key
        peer_wrong_key = %{peer | key: "wrongkey12345678", event: :none}
        assert {:error, :invalid_key} = Worker.announce(worker, peer_wrong_key, 50)
      after
        Application.put_env(:b1tpoti0n, :enforce_announce_key, old_val)
      end
    end

    test "requires key for returning peer", %{worker: worker} do
      # Enable announce key enforcement for this test
      old_val = Application.get_env(:b1tpoti0n, :enforce_announce_key, false)
      Application.put_env(:b1tpoti0n, :enforce_announce_key, true)

      try do
        peer = peer_data()

        # First announce gets a key
        {_, _, _, _, _announce_key} = Worker.announce(worker, peer, 50)

        # Return without key
        peer_no_key = %{peer | key: nil, event: :none}
        assert {:error, :key_required} = Worker.announce(worker, peer_no_key, 50)
      after
        Application.put_env(:b1tpoti0n, :enforce_announce_key, old_val)
      end
    end
  end

  describe "get_stats/1" do
    test "returns seeder, completed, leecher counts", %{worker: worker} do
      # Add some peers
      seeder = peer_data(ip: {192, 168, 1, 1}, left: 0)
      leecher1 = peer_data(ip: {192, 168, 1, 2}, left: 1000)
      leecher2 = peer_data(ip: {192, 168, 1, 3}, left: 500)

      Worker.announce(worker, seeder, 50)
      Worker.announce(worker, leecher1, 50)
      Worker.announce(worker, leecher2, 50)

      {seeders, completed, leechers} = Worker.get_stats(worker)

      assert seeders == 1
      assert completed == 0
      assert leechers == 2
    end
  end

  describe "get_peers/2" do
    test "returns peer list without processing announce", %{worker: worker} do
      # Add peers
      peer1 = peer_data(ip: {192, 168, 1, 1}, left: 0)
      peer2 = peer_data(ip: {192, 168, 1, 2}, left: 1000)

      Worker.announce(worker, peer1, 50)
      Worker.announce(worker, peer2, 50)

      peers = Worker.get_peers(worker, 50)

      assert length(peers) == 2
    end
  end

  describe "peer timeout cleanup" do
    test "expired peers are removed on cleanup" do
      info_hash = :crypto.strong_rand_bytes(20)
      {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})
      {:ok, worker} = Worker.start_link({info_hash, torrent.id})

      # Register a peer
      peer = peer_data()
      Worker.announce(worker, peer, 50)

      # Trigger cleanup manually (would normally happen via timer)
      send(worker, :cleanup)

      # Give it a moment to process
      Process.sleep(10)

      # Peer should still be there (not expired yet)
      {seeders, _, leechers} = Worker.get_stats(worker)
      assert seeders + leechers == 1

      GenServer.stop(worker)
    end
  end

  describe "seeder preference for leechers" do
    test "leechers receive seeders first", %{worker: worker} do
      # Add 5 seeders and 5 leechers
      Enum.each(1..5, fn i ->
        seeder = peer_data(ip: {192, 168, 1, i}, port: 6880 + i, left: 0, user_id: i)
        Worker.announce(worker, seeder, 50)
      end)

      Enum.each(6..10, fn i ->
        leecher = peer_data(ip: {192, 168, 2, i}, port: 6880 + i, left: 1000, user_id: i)
        Worker.announce(worker, leecher, 50)
      end)

      # New leecher asks for 5 peers
      new_leecher = peer_data(ip: {10, 0, 0, 1}, left: 1000, user_id: 100)
      {_, _, peers, _, _} = Worker.announce(worker, new_leecher, 5)

      # Should prefer seeders
      seeder_count = Enum.count(peers, & &1.is_seeder)
      # Due to randomization, most should be seeders
      assert seeder_count >= 3
    end
  end
end
