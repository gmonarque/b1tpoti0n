defmodule B1tpoti0n.Store.ManagerTest do
  @moduledoc """
  Tests for Store.Manager - ETS-based caching layer.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Persistence.Schemas.{Whitelist, BannedIp}

  setup do
    Repo.delete_all(Whitelist)
    Repo.delete_all(BannedIp)
    Manager.reload_passkeys()
    Manager.reload_whitelist()
    Manager.reload_banned_ips()
    :ok
  end

  describe "lookup_passkey/1" do
    test "returns {:ok, user_id} for valid passkey" do
      user = create_user()
      Manager.reload_passkeys()

      assert {:ok, user_id} = Manager.lookup_passkey(user.passkey)
      assert user_id == user.id
    end

    test "returns :error for unknown passkey" do
      assert :error = Manager.lookup_passkey("unknown_passkey_12345678901234")
    end

    test "reflects newly created users after reload" do
      user = create_user()

      assert :error = Manager.lookup_passkey(user.passkey)

      Manager.reload_passkeys()
      assert {:ok, _} = Manager.lookup_passkey(user.passkey)
    end
  end

  describe "valid_client?/1" do
    test "returns true for whitelisted client" do
      Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
      Manager.reload_whitelist()

      peer_id = "-TR3000-" <> :crypto.strong_rand_bytes(12)
      assert Manager.valid_client?(peer_id) == true
    end

    test "returns false for non-whitelisted client" do
      Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
      Manager.reload_whitelist()

      peer_id = "-XX0000-" <> :crypto.strong_rand_bytes(12)
      assert Manager.valid_client?(peer_id) == false
    end

    test "returns false for empty peer_id" do
      assert Manager.valid_client?("") == false
    end

    test "returns false for short peer_id" do
      assert Manager.valid_client?("-T") == false
    end

    test "checks first 3 characters only" do
      Repo.insert!(%Whitelist{client_prefix: "-TR", name: "Transmission"})
      Manager.reload_whitelist()

      assert Manager.valid_client?("-TR1000-xxxxxxxxxxxx") == true
      assert Manager.valid_client?("-TR2000-xxxxxxxxxxxx") == true
      assert Manager.valid_client?("-TR9999-xxxxxxxxxxxx") == true
    end
  end

  describe "check_banned/1" do
    test "returns :ok for non-banned IP" do
      assert :ok = Manager.check_banned("192.168.1.100")
    end

    test "returns {:banned, reason} for banned IP" do
      B1tpoti0n.Admin.ban_ip("192.168.1.100", "Test ban")

      assert {:banned, "Test ban"} = Manager.check_banned("192.168.1.100")
    end

    test "matches CIDR ranges" do
      B1tpoti0n.Admin.ban_ip("10.0.0.0/8", "Internal network")

      assert {:banned, "Internal network"} = Manager.check_banned("10.1.2.3")
      assert {:banned, "Internal network"} = Manager.check_banned("10.255.255.255")
      assert :ok = Manager.check_banned("11.0.0.1")
    end

    test "accepts IP tuple format" do
      B1tpoti0n.Admin.ban_ip("192.168.1.100", "Test ban")

      assert {:banned, "Test ban"} = Manager.check_banned({192, 168, 1, 100})
    end

    test "ignores expired bans" do
      B1tpoti0n.Admin.ban_ip("192.168.1.100", "Expired ban", duration: -3600)

      assert :ok = Manager.check_banned("192.168.1.100")
    end

    test "respects non-expired bans" do
      B1tpoti0n.Admin.ban_ip("192.168.1.100", "Active ban", duration: 3600)

      assert {:banned, "Active ban"} = Manager.check_banned("192.168.1.100")
    end
  end

  describe "reload functions" do
    test "reload_passkeys/0 updates ETS from database" do
      user = create_user()
      assert :error = Manager.lookup_passkey(user.passkey)

      Manager.reload_passkeys()
      assert {:ok, _} = Manager.lookup_passkey(user.passkey)
    end

    test "reload_whitelist/0 updates ETS from database" do
      peer_id = "-NW0000-" <> :crypto.strong_rand_bytes(12)
      assert Manager.valid_client?(peer_id) == false

      Repo.insert!(%Whitelist{client_prefix: "-NW", name: "New Client"})
      Manager.reload_whitelist()

      assert Manager.valid_client?(peer_id) == true
    end

    test "reload_banned_ips/0 updates ETS from database" do
      assert :ok = Manager.check_banned("192.168.1.100")

      B1tpoti0n.Admin.ban_ip("192.168.1.100", "Banned")

      assert {:banned, _} = Manager.check_banned("192.168.1.100")
    end
  end

  describe "stats/0" do
    test "returns counts for all tables" do
      stats = Manager.stats()

      assert Map.has_key?(stats, :passkeys)
      assert Map.has_key?(stats, :whitelist)
      assert Map.has_key?(stats, :banned_ips)

      assert is_integer(stats.passkeys)
      assert is_integer(stats.whitelist)
      assert is_integer(stats.banned_ips)
    end

    test "reflects actual table sizes" do
      _user1 = create_user()
      _user2 = create_user()
      Manager.reload_passkeys()

      Repo.insert!(%Whitelist{client_prefix: "-T1", name: "Client 1"})
      Repo.insert!(%Whitelist{client_prefix: "-T2", name: "Client 2"})
      Manager.reload_whitelist()

      stats = Manager.stats()
      assert stats.passkeys == 2
      assert stats.whitelist == 2
    end
  end
end
