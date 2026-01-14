defmodule B1tpoti0n.PrivateTrackerTest do
  @moduledoc """
  Tests for private tracker features:
  - Freeleech and multipliers
  - Snatch tracking
  - HnR detection
  - Ratio enforcement
  """
  use B1tpoti0n.DataCase, async: true

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.{Torrent, User, Snatch}
  alias B1tpoti0n.Torrents
  alias B1tpoti0n.Snatches

  describe "Torrent freeleech" do
    test "freeleech_active? returns false when not enabled" do
      torrent = %Torrent{freeleech: false}
      refute Torrent.freeleech_active?(torrent)
    end

    test "freeleech_active? returns true when enabled without expiry" do
      torrent = %Torrent{freeleech: true, freeleech_until: nil}
      assert Torrent.freeleech_active?(torrent)
    end

    test "freeleech_active? returns true when enabled and not expired" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      torrent = %Torrent{freeleech: true, freeleech_until: future}
      assert Torrent.freeleech_active?(torrent)
    end

    test "freeleech_active? returns false when expired" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      torrent = %Torrent{freeleech: true, freeleech_until: past}
      refute Torrent.freeleech_active?(torrent)
    end

    test "effective_download_multiplier returns 0.0 when freeleech active" do
      torrent = %Torrent{freeleech: true, freeleech_until: nil, download_multiplier: 1.0}
      assert Torrent.effective_download_multiplier(torrent) == 0.0
    end

    test "effective_download_multiplier returns multiplier when not freeleech" do
      torrent = %Torrent{freeleech: false, download_multiplier: 0.5}
      assert Torrent.effective_download_multiplier(torrent) == 0.5
    end
  end

  describe "Torrent multipliers" do
    setup do
      # Use direct insert to avoid validation issues with binary in test
      info_hash = :crypto.strong_rand_bytes(20)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, torrent} =
        Repo.insert(%Torrent{
          info_hash: info_hash,
          seeders: 0,
          leechers: 0,
          completed: 0,
          freeleech: false,
          upload_multiplier: 1.0,
          download_multiplier: 1.0,
          inserted_at: now,
          updated_at: now
        })

      %{torrent: torrent}
    end

    test "set_multipliers updates torrent multipliers", %{torrent: torrent} do
      {:ok, updated} = Torrents.set_multipliers(torrent.id, 2.0, 0.5)
      assert updated.upload_multiplier == 2.0
      assert updated.download_multiplier == 0.5
    end

    test "set_freeleech enables freeleech", %{torrent: torrent} do
      {:ok, updated} = Torrents.set_freeleech(torrent.id, true)
      assert updated.freeleech == true
      assert updated.freeleech_until == nil
    end

    test "set_freeleech with duration sets expiry", %{torrent: torrent} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, updated} = Torrents.set_freeleech(torrent.id, true, future)
      assert updated.freeleech == true
      assert updated.freeleech_until != nil
    end

    test "get_settings returns correct values", %{torrent: torrent} do
      {:ok, updated} = Torrents.set_multipliers(torrent.id, 2.5, 0.75)
      settings = Torrents.get_settings(updated)

      assert settings.freeleech_active == false
      assert settings.upload_multiplier == 2.5
      assert settings.download_multiplier == 0.75
    end

    test "get_settings with freeleech returns 0.0 download multiplier", %{torrent: torrent} do
      {:ok, updated} = Torrents.set_freeleech(torrent.id, true)
      settings = Torrents.get_settings(updated)

      assert settings.freeleech_active == true
      assert settings.download_multiplier == 0.0
    end
  end

  describe "Snatch tracking" do
    setup do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        Repo.insert(%User{
          passkey: User.generate_passkey(),
          uploaded: 0,
          downloaded: 0,
          hnr_warnings: 0,
          can_leech: true,
          required_ratio: 0.0,
          inserted_at: now,
          updated_at: now
        })

      info_hash = :crypto.strong_rand_bytes(20)

      {:ok, torrent} =
        Repo.insert(%Torrent{
          info_hash: info_hash,
          seeders: 0,
          leechers: 0,
          completed: 0,
          freeleech: false,
          upload_multiplier: 1.0,
          download_multiplier: 1.0,
          inserted_at: now,
          updated_at: now
        })

      %{user: user, torrent: torrent}
    end

    test "record_snatch creates snatch record", %{user: user, torrent: torrent} do
      {:ok, snatch} = Snatches.record_snatch(user.id, torrent.id)

      assert snatch.user_id == user.id
      assert snatch.torrent_id == torrent.id
      assert snatch.seedtime == 0
      assert snatch.completed_at != nil
    end

    test "record_snatch is idempotent", %{user: user, torrent: torrent} do
      {:ok, _snatch1} = Snatches.record_snatch(user.id, torrent.id)
      {:ok, snatch2} = Snatches.record_snatch(user.id, torrent.id)

      # Second call should return existing snatch (fetched from DB)
      assert snatch2 != nil
      assert snatch2.user_id == user.id
      assert snatch2.torrent_id == torrent.id
    end

    test "update_seedtime increments seedtime", %{user: user, torrent: torrent} do
      {:ok, snatch} = Snatches.record_snatch(user.id, torrent.id)

      # Simulate time passing
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(s in Snatch, where: s.id == ^snatch.id),
        set: [last_announce_at: past]
      )

      Snatches.update_seedtime(user.id, torrent.id)

      updated_snatch = Snatches.get_snatch(user.id, torrent.id)
      assert updated_snatch.seedtime > 0
      # Capped at 2 hours
      assert updated_snatch.seedtime <= 7200
    end

    test "list_user_snatches returns all user's snatches", %{user: user, torrent: torrent} do
      {:ok, _snatch} = Snatches.record_snatch(user.id, torrent.id)

      # Create another torrent and snatch
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      info_hash2 = :crypto.strong_rand_bytes(20)

      {:ok, torrent2} =
        Repo.insert(%Torrent{
          info_hash: info_hash2,
          seeders: 0,
          leechers: 0,
          completed: 0,
          freeleech: false,
          upload_multiplier: 1.0,
          download_multiplier: 1.0,
          inserted_at: now,
          updated_at: now
        })

      {:ok, _snatch2} = Snatches.record_snatch(user.id, torrent2.id)

      snatches = Snatches.list_user_snatches(user.id)
      assert length(snatches) == 2
    end

    test "list_torrent_snatches returns all torrent's snatchers", %{user: user, torrent: torrent} do
      {:ok, _snatch} = Snatches.record_snatch(user.id, torrent.id)

      snatches = Snatches.list_torrent_snatches(torrent.id)
      assert length(snatches) == 1
      assert hd(snatches).user_id == user.id
    end
  end

  describe "User ratio calculation" do
    test "ratio returns :infinity when downloaded is 0" do
      user = %User{uploaded: 1000, downloaded: 0}
      assert User.ratio(user) == :infinity
    end

    test "ratio calculates correctly" do
      user = %User{uploaded: 2000, downloaded: 1000}
      assert User.ratio(user) == 2.0
    end
  end

  describe "Snatch seed_ratio" do
    test "seed_ratio calculates correctly" do
      # 10 hours
      snatch = %Snatch{seedtime: 36000}
      # 72 hours required = 259200 seconds
      assert Snatch.seed_ratio(snatch, 259_200) == 36000 / 259_200
    end

    test "seed_ratio returns 0.0 when required_seedtime is 0" do
      snatch = %Snatch{seedtime: 36000}
      assert Snatch.seed_ratio(snatch, 0) == 0.0
    end
  end

  describe "HnR detector" do
    test "stats returns HnR configuration" do
      stats = B1tpoti0n.Hnr.Detector.stats()

      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :last_check)
      assert Map.has_key?(stats, :config)
    end
  end
end
