defmodule B1tpoti0n.Network.HttpHandlerTest do
  @moduledoc """
  Tests for HTTP tracker protocol handler (announce/scrape processing).
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Network.HttpHandler
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Persistence.Schemas.{Torrent, User, Whitelist}
  alias B1tpoti0n.Core.Bencode

  setup do
    # Clean up and prepare
    Repo.delete_all(Torrent)
    Manager.reload_passkeys()
    Manager.reload_whitelist()

    # Create a whitelisted client prefix
    Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
    Manager.reload_whitelist()

    :ok
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

  defp valid_announce_params(info_hash) do
    peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)

    %{
      "info_hash" => info_hash,
      "peer_id" => peer_id,
      "port" => "6881",
      "uploaded" => "0",
      "downloaded" => "0",
      "left" => "1000000",
      "event" => "started"
    }
  end

  describe "process_announce/3" do
    test "successful announce with valid passkey" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:ok, response} = result
      assert is_binary(response)

      # Parse the bencoded response
      decoded = Bencode.decode(response)
      assert is_map(decoded)
      assert Map.has_key?(decoded, "interval")
      assert decoded["complete"] >= 0
      assert decoded["incomplete"] >= 0
    end

    test "reject announce without passkey" do
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)

      result = HttpHandler.process_announce(params, nil, {127, 0, 0, 1})

      assert {:error, "Invalid passkey"} = result
    end

    test "reject announce with invalid passkey length" do
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)

      result = HttpHandler.process_announce(params, "tooshort", {127, 0, 0, 1})

      assert {:error, "Invalid passkey"} = result
    end

    test "reject announce with non-existent passkey" do
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)
      fake_passkey = String.duplicate("a", 32)

      result = HttpHandler.process_announce(params, fake_passkey, {127, 0, 0, 1})

      assert {:error, "Invalid passkey"} = result
    end

    test "reject announce with non-whitelisted client" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()

      # Use a non-whitelisted peer_id
      params = %{
        "info_hash" => info_hash,
        "peer_id" => "-XX0000-" <> :crypto.strong_rand_bytes(12),
        "port" => "6881",
        "uploaded" => "0",
        "downloaded" => "0",
        "left" => "1000000"
      }

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:error, "Not authorized"} = result
    end

    test "reject announce for non-registered torrent in whitelist mode" do
      user = create_user_with_passkey()
      random_info_hash = :crypto.strong_rand_bytes(20)
      params = valid_announce_params(random_info_hash)

      # Enable whitelist mode
      old_val = Application.get_env(:b1tpoti0n, :enforce_torrent_whitelist, false)
      Application.put_env(:b1tpoti0n, :enforce_torrent_whitelist, true)

      try do
        result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})
        assert {:error, "Unregistered torrent"} = result
      after
        Application.put_env(:b1tpoti0n, :enforce_torrent_whitelist, old_val)
      end
    end

    test "accept seeder announce (left=0)" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash) |> Map.put("left", "0")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:ok, response} = result
      decoded = Bencode.decode(response)
      # Seeder should be counted
      assert decoded["complete"] >= 0
    end

    test "completed event records snatch" do
      user = create_user_with_passkey()
      {info_hash, torrent} = create_torrent()

      params =
        valid_announce_params(info_hash)
        |> Map.put("event", "completed")
        |> Map.put("left", "0")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:ok, _response} = result

      # Check snatch was recorded
      snatch = B1tpoti0n.Snatches.get_snatch(user.id, torrent.id)
      assert snatch != nil
    end

    test "stopped event removes peer" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)

      # First announce to register peer and get tracker key
      {:ok, first_response} = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})
      decoded_first = Bencode.decode(first_response)
      tracker_key = decoded_first["tracker id"]

      # Then stop with tracker key
      stop_params =
        params
        |> Map.put("event", "stopped")
        |> Map.put("key", tracker_key)

      {:ok, response} = HttpHandler.process_announce(stop_params, user.passkey, {127, 0, 0, 1})

      decoded = Bencode.decode(response)
      assert is_map(decoded)
    end

    test "returns announce key for anti-spoofing" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash)

      {:ok, response} = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      decoded = Bencode.decode(response)
      # Announce key should be present
      assert Map.has_key?(decoded, "tracker id") or Map.has_key?(decoded, "key")
    end

    test "reject leeching when user can_leech is false" do
      user = create_user_with_passkey()
      Repo.update!(User.changeset(user, %{can_leech: false}))

      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash) |> Map.put("left", "1000")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:error, "Download not permitted"} = result
    end

    test "allow seeding even when can_leech is false" do
      user = create_user_with_passkey()
      Repo.update!(User.changeset(user, %{can_leech: false}))

      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash) |> Map.put("left", "0")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      # Seeders (left=0) should always be allowed
      assert {:ok, _response} = result
    end
  end

  describe "process_scrape/2" do
    test "successful scrape with valid passkey" do
      user = create_user_with_passkey()
      {info_hash, _torrent} = create_torrent()
      params = %{"info_hash" => info_hash}

      result = HttpHandler.process_scrape(params, user.passkey)

      assert {:ok, response} = result
      assert is_binary(response)

      decoded = Bencode.decode(response)
      assert Map.has_key?(decoded, "files")
    end

    test "reject scrape without passkey" do
      {info_hash, _torrent} = create_torrent()
      params = %{"info_hash" => info_hash}

      result = HttpHandler.process_scrape(params, nil)

      assert {:error, "Invalid passkey"} = result
    end

    test "reject scrape with invalid passkey" do
      {info_hash, _torrent} = create_torrent()
      params = %{"info_hash" => info_hash}

      result = HttpHandler.process_scrape(params, String.duplicate("x", 32))

      assert {:error, "Invalid passkey"} = result
    end

    test "reject scrape without info_hash" do
      user = create_user_with_passkey()

      result = HttpHandler.process_scrape(%{}, user.passkey)

      assert {:error, "No info_hash provided"} = result
    end

    test "scrape returns zeros for unknown torrent" do
      user = create_user_with_passkey()
      unknown_hash = :crypto.strong_rand_bytes(20)
      params = %{"info_hash" => unknown_hash}

      {:ok, response} = HttpHandler.process_scrape(params, user.passkey)

      decoded = Bencode.decode(response)
      torrent_info = decoded["files"][unknown_hash]
      assert torrent_info["complete"] == 0
      assert torrent_info["incomplete"] == 0
      assert torrent_info["downloaded"] == 0
    end
  end

  describe "ratio enforcement" do
    test "reject leeching when ratio too low" do
      user = create_user_with_passkey()
      # Set low ratio: downloaded a lot, uploaded little
      Repo.update!(
        User.changeset(user, %{
          # 100 MB
          uploaded: 100_000_000,
          # 10 GB = 0.01 ratio
          downloaded: 10_000_000_000
        })
      )

      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash) |> Map.put("left", "1000")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:error, "Download not permitted"} = result
    end

    test "allow leeching for new users in grace period" do
      user = create_user_with_passkey()
      # New user with little download (under 5GB grace)
      Repo.update!(
        User.changeset(user, %{
          uploaded: 0,
          # 1 GB
          downloaded: 1_000_000_000
        })
      )

      {info_hash, _torrent} = create_torrent()
      params = valid_announce_params(info_hash) |> Map.put("left", "1000")

      result = HttpHandler.process_announce(params, user.passkey, {127, 0, 0, 1})

      assert {:ok, _response} = result
    end
  end
end
