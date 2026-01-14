defmodule B1tpoti0n.Stats.BufferTest do
  @moduledoc """
  Tests for Stats.Buffer - in-memory stats aggregation.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Stats.Buffer

  setup do
    Buffer.flush()
    :ok
  end

  describe "record_transfer/3" do
    test "records upload and download stats for user" do
      Buffer.record_transfer(1, 1000, 500)

      stats = Buffer.flush()
      assert length(stats.users) == 1

      user_stat = hd(stats.users)
      assert user_stat.user_id == 1
      assert user_stat.uploaded == 1000
      assert user_stat.downloaded == 500
    end

    test "accumulates stats for same user" do
      Buffer.record_transfer(1, 1000, 500)
      Buffer.record_transfer(1, 2000, 1000)
      Buffer.record_transfer(1, 500, 250)

      stats = Buffer.flush()
      user_stat = hd(stats.users)

      assert user_stat.uploaded == 3500
      assert user_stat.downloaded == 1750
    end

    test "tracks multiple users separately" do
      Buffer.record_transfer(1, 1000, 500)
      Buffer.record_transfer(2, 2000, 1000)
      Buffer.record_transfer(3, 3000, 1500)

      stats = Buffer.flush()
      assert length(stats.users) == 3
    end

    test "ignores nil user_id" do
      Buffer.record_transfer(nil, 1000, 500)

      stats = Buffer.flush()
      assert stats.users == []
    end
  end

  describe "record_torrent_stats/3" do
    test "records seeder and leecher counts" do
      Buffer.record_torrent_stats(1, 10, 5)

      stats = Buffer.flush()
      assert length(stats.torrents) == 1

      torrent_stat = hd(stats.torrents)
      assert torrent_stat.torrent_id == 1
      assert torrent_stat.seeders == 10
      assert torrent_stat.leechers == 5
    end

    test "overwrites previous torrent stats" do
      Buffer.record_torrent_stats(1, 10, 5)
      Buffer.record_torrent_stats(1, 15, 8)

      stats = Buffer.flush()
      assert length(stats.torrents) == 1

      torrent_stat = hd(stats.torrents)
      assert torrent_stat.seeders == 15
      assert torrent_stat.leechers == 8
    end
  end

  describe "flush/0" do
    test "returns stats and clears buffer" do
      Buffer.record_transfer(1, 1000, 500)
      Buffer.record_transfer(2, 2000, 1000)

      stats = Buffer.flush()
      assert length(stats.users) == 2

      stats2 = Buffer.flush()
      assert stats2.users == []
      assert stats2.torrents == []
    end

    test "separates user and torrent stats" do
      Buffer.record_transfer(1, 1000, 500)
      Buffer.record_torrent_stats(1, 10, 5)

      stats = Buffer.flush()
      assert length(stats.users) == 1
      assert length(stats.torrents) == 1
    end
  end

  describe "size/0" do
    test "returns number of entries in buffer" do
      assert Buffer.size() == 0

      Buffer.record_transfer(1, 1000, 500)
      assert Buffer.size() == 1

      Buffer.record_transfer(2, 2000, 1000)
      assert Buffer.size() == 2

      Buffer.record_torrent_stats(1, 10, 5)
      assert Buffer.size() == 3

      Buffer.flush()
      assert Buffer.size() == 0
    end
  end

  describe "concurrent access" do
    test "handles concurrent writes safely" do
      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            Buffer.record_transfer(i, 1000, 500)
          end)
        end)

      Enum.each(tasks, &Task.await/1)

      stats = Buffer.flush()
      assert length(stats.users) == 100
    end
  end
end
