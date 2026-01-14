defmodule B1tpoti0n.Hnr.DetectorTest do
  @moduledoc """
  Tests for Hit-and-Run detection logic.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Hnr.Detector
  alias B1tpoti0n.Persistence.Schemas.{User, Snatch, Torrent}

  setup do
    # Enable HnR detection for tests
    old_config = Application.get_env(:b1tpoti0n, :hnr)

    Application.put_env(:b1tpoti0n, :hnr,
      # 1 hour minimum
      min_seedtime: 3600,
      # 1 day grace period
      grace_period_days: 1,
      max_warnings: 3
    )

    on_exit(fn ->
      if old_config do
        Application.put_env(:b1tpoti0n, :hnr, old_config)
      else
        Application.delete_env(:b1tpoti0n, :hnr)
      end
    end)

    :ok
  end

  defp create_torrent do
    info_hash = :crypto.strong_rand_bytes(20)
    {:ok, torrent} = Repo.insert(%Torrent{info_hash: info_hash})
    torrent
  end

  defp create_snatch(user, torrent, opts) do
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now())
    seedtime = Keyword.get(opts, :seedtime, 0)
    hnr = Keyword.get(opts, :hnr, false)

    {:ok, snatch} =
      Repo.insert(%Snatch{
        user_id: user.id,
        torrent_id: torrent.id,
        completed_at: DateTime.truncate(completed_at, :second),
        seedtime: seedtime,
        hnr: hnr
      })

    snatch
  end

  describe "stats/0" do
    test "returns HnR statistics" do
      stats = Detector.stats()

      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :last_check)
      assert Map.has_key?(stats, :hnr_count)
      assert Map.has_key?(stats, :warnings_issued)
      assert Map.has_key?(stats, :config)
    end

    test "returns enabled: true when configured" do
      stats = Detector.stats()
      assert stats.enabled == true
    end
  end

  describe "clear_hnr/1" do
    test "clears HnR flag on snatch" do
      user = create_user()
      torrent = create_torrent()
      snatch = create_snatch(user, torrent, hnr: true)

      assert snatch.hnr == true

      assert :ok = Detector.clear_hnr(snatch.id)

      updated = Repo.get!(Snatch, snatch.id)
      assert updated.hnr == false
    end

    test "returns error for non-existent snatch" do
      assert {:error, :not_found} = Detector.clear_hnr(999_999)
    end
  end

  describe "clear_user_warnings/1" do
    test "clears user HnR warnings and re-enables leeching" do
      user = create_user()
      Repo.update!(User.changeset(user, %{hnr_warnings: 5, can_leech: false}))

      assert :ok = Detector.clear_user_warnings(user.id)

      updated = Repo.get!(User, user.id)
      assert updated.hnr_warnings == 0
      assert updated.can_leech == true
    end

    test "returns error for non-existent user" do
      assert {:error, :not_found} = Detector.clear_user_warnings(999_999)
    end
  end

  describe "HnR detection logic" do
    test "marks snatches as HnR after grace period with insufficient seedtime" do
      user = create_user()
      torrent = create_torrent()

      # Snatch completed 2 days ago with only 100 seconds seedtime
      # (grace period is 1 day, min seedtime is 1 hour)
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86400, :second)
      snatch = create_snatch(user, torrent, completed_at: two_days_ago, seedtime: 100)

      # Manually trigger check via internal function
      # (We can't easily test the GenServer cast without waiting)
      send(Detector, :check)
      # Give it time to process
      Process.sleep(50)

      updated = Repo.get!(Snatch, snatch.id)
      assert updated.hnr == true
    end

    test "does not mark snatches within grace period" do
      user = create_user()
      torrent = create_torrent()

      # Snatch completed 6 hours ago (within 1 day grace)
      six_hours_ago = DateTime.add(DateTime.utc_now(), -6 * 3600, :second)
      snatch = create_snatch(user, torrent, completed_at: six_hours_ago, seedtime: 0)

      send(Detector, :check)
      Process.sleep(50)

      updated = Repo.get!(Snatch, snatch.id)
      assert updated.hnr == false
    end

    test "does not mark snatches with sufficient seedtime" do
      user = create_user()
      torrent = create_torrent()

      # Snatch completed 2 days ago with 2 hours seedtime (> 1 hour minimum)
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86400, :second)
      snatch = create_snatch(user, torrent, completed_at: two_days_ago, seedtime: 7200)

      send(Detector, :check)
      Process.sleep(50)

      updated = Repo.get!(Snatch, snatch.id)
      assert updated.hnr == false
    end

    test "increments user warnings on HnR" do
      user = create_user()
      torrent = create_torrent()

      initial_warnings = user.hnr_warnings

      # Create HnR-eligible snatch
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86400, :second)
      _snatch = create_snatch(user, torrent, completed_at: two_days_ago, seedtime: 0)

      send(Detector, :check)
      Process.sleep(50)

      updated_user = Repo.get!(User, user.id)
      assert updated_user.hnr_warnings > initial_warnings
    end

    test "disables leeching when max warnings exceeded" do
      user = create_user()
      # 2 warnings already
      Repo.update!(User.changeset(user, %{hnr_warnings: 2}))

      torrent = create_torrent()

      # Create HnR-eligible snatch (will push to 3 warnings = max)
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86400, :second)
      _snatch = create_snatch(user, torrent, completed_at: two_days_ago, seedtime: 0)

      send(Detector, :check)
      Process.sleep(50)

      updated_user = Repo.get!(User, user.id)
      assert updated_user.hnr_warnings >= 3
      assert updated_user.can_leech == false
    end
  end
end
