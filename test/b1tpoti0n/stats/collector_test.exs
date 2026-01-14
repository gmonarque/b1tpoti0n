defmodule B1tpoti0n.Stats.CollectorTest do
  @moduledoc """
  Tests for Stats.Collector - periodic stats flushing to database.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Stats.{Buffer, Collector}
  alias B1tpoti0n.Persistence.Schemas.{User, Torrent}

  setup do
    Buffer.flush()
    :ok
  end

  describe "force_flush/0" do
    test "flushes user stats to database" do
      user = create_user()
      initial_uploaded = user.uploaded

      Buffer.record_transfer(user.id, 5000, 2500)
      Collector.force_flush()

      updated_user = Repo.get!(User, user.id)
      assert updated_user.uploaded == initial_uploaded + 5000
      assert updated_user.downloaded == 2500
    end

    test "flushes torrent stats to database" do
      info_hash = :crypto.strong_rand_bytes(20)
      {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})

      Buffer.record_torrent_stats(torrent.id, 10, 5)
      Collector.force_flush()

      updated_torrent = Repo.get!(Torrent, torrent.id)
      assert updated_torrent.seeders == 10
      assert updated_torrent.leechers == 5
    end

    test "clears buffer after flush" do
      user = create_user()
      Buffer.record_transfer(user.id, 5000, 2500)

      Collector.force_flush()

      assert Buffer.size() == 0
    end

    test "handles multiple users" do
      user1 = create_user()
      user2 = create_user()
      user3 = create_user()

      Buffer.record_transfer(user1.id, 1000, 500)
      Buffer.record_transfer(user2.id, 2000, 1000)
      Buffer.record_transfer(user3.id, 3000, 1500)

      Collector.force_flush()

      assert Repo.get!(User, user1.id).uploaded == 1000
      assert Repo.get!(User, user2.id).uploaded == 2000
      assert Repo.get!(User, user3.id).uploaded == 3000
    end

    test "accumulates stats across multiple flushes" do
      user = create_user()

      Buffer.record_transfer(user.id, 1000, 500)
      Collector.force_flush()

      Buffer.record_transfer(user.id, 2000, 1000)
      Collector.force_flush()

      updated_user = Repo.get!(User, user.id)
      assert updated_user.uploaded == 3000
      assert updated_user.downloaded == 1500
    end

    test "handles non-existent user gracefully" do
      Buffer.record_transfer(999_999, 1000, 500)
      assert :ok = Collector.force_flush()
    end

    test "handles non-existent torrent gracefully" do
      Buffer.record_torrent_stats(999_999, 10, 5)
      assert :ok = Collector.force_flush()
    end
  end
end
