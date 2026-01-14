defmodule B1tpoti0n.Network.AdminRouterTest do
  @moduledoc """
  Tests for the Admin REST API router.
  """
  use B1tpoti0n.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias B1tpoti0n.Network.AdminRouter
  alias B1tpoti0n.Persistence.Schemas.{BannedIp, Snatch, Torrent}
  alias B1tpoti0n.Store.Manager

  setup do
    # Clean up
    Repo.delete_all(Snatch)
    Repo.delete_all(Torrent)
    Repo.delete_all(BannedIp)
    Manager.reload_banned_ips()
    :ok
  end

  # Get token at runtime
  defp admin_token do
    Application.get_env(:b1tpoti0n, :admin_token) || "test_admin_token_12345"
  end

  # Helper to make authenticated requests
  defp call(conn) do
    conn
    |> put_req_header("x-admin-token", admin_token())
    |> put_req_header("content-type", "application/json")
    |> AdminRouter.call(AdminRouter.init([]))
  end

  defp json_body(conn) do
    conn.resp_body |> Jason.decode!()
  end

  # Create a torrent using repo directly (bypassing changeset validation)
  defp create_torrent do
    info_hash = :crypto.strong_rand_bytes(20)

    {:ok, torrent} =
      Repo.insert(%Torrent{
        info_hash: info_hash,
        seeders: 0,
        leechers: 0,
        completed: 0
      })

    torrent
  end

  describe "authentication" do
    test "rejects requests without token" do
      conn =
        conn(:get, "/users")
        |> AdminRouter.call(AdminRouter.init([]))

      assert conn.status == 401
      assert json_body(conn)["error"] == "Unauthorized"
    end

    test "rejects requests with invalid token" do
      conn =
        conn(:get, "/users")
        |> put_req_header("x-admin-token", "wrong_token")
        |> AdminRouter.call(AdminRouter.init([]))

      assert conn.status == 401
    end

    test "accepts requests with valid token" do
      conn =
        conn(:get, "/users")
        |> call()

      assert conn.status == 200
    end
  end

  describe "GET /users" do
    test "returns list of users" do
      _user = create_user()

      conn = conn(:get, "/users") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert length(body["data"]) == 1
    end
  end

  describe "GET /users/search" do
    test "searches users by partial passkey" do
      user = create_user(%{passkey: "abcdef1234567890abcdef1234567890"})
      _other = create_user()

      conn = conn(:get, "/users/search?q=abcdef") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert length(body["data"]) == 1
      assert hd(body["data"])["id"] == user.id
    end

    test "returns error without query param" do
      conn = conn(:get, "/users/search") |> call()

      assert conn.status == 400
      assert json_body(conn)["error"] =~ "3 characters"
    end
  end

  describe "GET /users/passkey/:passkey" do
    test "returns user by exact passkey" do
      user = create_user(%{passkey: "exactpasskey12345678901234567890"})

      conn = conn(:get, "/users/passkey/exactpasskey12345678901234567890") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert body["data"]["id"] == user.id
    end

    test "returns 404 for non-existent passkey" do
      conn = conn(:get, "/users/passkey/doesnotexist123456789012345678") |> call()

      assert conn.status == 404
      assert json_body(conn)["error"] == "User not found"
    end
  end

  describe "PUT /users/:id/stats" do
    test "updates user uploaded and downloaded" do
      user = create_user()

      conn =
        conn(:put, "/users/#{user.id}/stats", Jason.encode!(%{uploaded: 1000, downloaded: 500}))
        |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert body["data"]["uploaded"] == 1000
      assert body["data"]["downloaded"] == 500
    end

    test "supports add operation" do
      user = create_user()
      # First set some initial values
      conn(:put, "/users/#{user.id}/stats", Jason.encode!(%{uploaded: 1000})) |> call()

      # Add to existing
      conn =
        conn(:put, "/users/#{user.id}/stats", Jason.encode!(%{uploaded: 500, operation: "add"}))
        |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["data"]["uploaded"] == 1500
    end

    test "returns 404 for non-existent user" do
      conn =
        conn(:put, "/users/999999/stats", Jason.encode!(%{uploaded: 1000}))
        |> call()

      assert conn.status == 404
    end
  end

  describe "PUT /users/:id/leech" do
    test "disables leeching" do
      user = create_user()

      conn =
        conn(:put, "/users/#{user.id}/leech", Jason.encode!(%{can_leech: false}))
        |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["data"]["can_leech"] == false
    end

    test "enables leeching" do
      user = create_user()
      # First disable
      conn(:put, "/users/#{user.id}/leech", Jason.encode!(%{can_leech: false})) |> call()

      # Then enable
      conn =
        conn(:put, "/users/#{user.id}/leech", Jason.encode!(%{can_leech: true}))
        |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["can_leech"] == true
    end
  end

  describe "POST /users/:id/warnings/clear" do
    test "clears user warnings" do
      user = create_user()

      conn = conn(:post, "/users/#{user.id}/warnings/clear") |> call()

      assert conn.status == 200
      assert json_body(conn)["success"] == true
    end
  end

  describe "torrents endpoints" do
    test "GET /torrents returns empty list" do
      conn = conn(:get, "/torrents") |> call()

      assert conn.status == 200
      assert json_body(conn)["data"] == []
    end

    test "POST /torrents creates a torrent" do
      info_hash_hex = :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)

      conn =
        conn(:post, "/torrents", Jason.encode!(%{info_hash: info_hash_hex}))
        |> call()

      assert conn.status == 201
      body = json_body(conn)
      assert body["success"] == true
      assert body["data"]["info_hash"] == info_hash_hex
    end

    test "PUT /torrents/:id/stats updates torrent stats" do
      torrent = create_torrent()

      conn =
        conn(
          :put,
          "/torrents/#{torrent.id}/stats",
          Jason.encode!(%{seeders: 10, leechers: 5, completed: 100})
        )
        |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["data"]["seeders"] == 10
      assert body["data"]["leechers"] == 5
      assert body["data"]["completed"] == 100
    end
  end

  describe "bans endpoints" do
    test "POST /bans creates a ban" do
      conn =
        conn(:post, "/bans", Jason.encode!(%{ip: "192.168.1.100", reason: "Test ban"}))
        |> call()

      assert conn.status == 201
      body = json_body(conn)
      assert body["success"] == true
      assert body["data"]["ip"] == "192.168.1.100"
    end

    test "GET /bans/active returns only active bans" do
      {:ok, _} = B1tpoti0n.Admin.ban_ip("192.168.1.1", "Active")
      {:ok, _} = B1tpoti0n.Admin.ban_ip("192.168.1.2", "Expired", duration: -3600)

      conn = conn(:get, "/bans/active") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert length(body["data"]) == 1
      assert hd(body["data"])["ip"] == "192.168.1.1"
    end

    test "PUT /bans/:ip updates existing ban" do
      {:ok, _} = B1tpoti0n.Admin.ban_ip("192.168.1.100", "Original reason")

      conn =
        conn(:put, "/bans/192.168.1.100", Jason.encode!(%{reason: "Updated reason"}))
        |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["reason"] == "Updated reason"
    end

    test "POST /bans/cleanup removes expired bans" do
      {:ok, _} = B1tpoti0n.Admin.ban_ip("192.168.1.1", "Active")
      {:ok, _} = B1tpoti0n.Admin.ban_ip("192.168.1.2", "Expired", duration: -3600)

      conn = conn(:post, "/bans/cleanup") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert body["message"] =~ "1 expired bans"
    end
  end

  describe "snatches endpoints" do
    setup do
      user = create_user()
      torrent = create_torrent()
      {:ok, snatch} = B1tpoti0n.Snatches.record_snatch(user.id, torrent.id)
      {:ok, user: user, torrent: torrent, snatch: snatch}
    end

    test "GET /snatches/:id returns a snatch", %{snatch: snatch} do
      conn = conn(:get, "/snatches/#{snatch.id}") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["data"]["id"] == snatch.id
    end

    test "PUT /snatches/:id updates a snatch", %{snatch: snatch} do
      conn =
        conn(:put, "/snatches/#{snatch.id}", Jason.encode!(%{seedtime: 7200}))
        |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["seedtime"] == 7200
    end

    test "DELETE /snatches/:id removes a snatch", %{snatch: snatch} do
      conn = conn(:delete, "/snatches/#{snatch.id}") |> call()

      assert conn.status == 200
      assert json_body(conn)["success"] == true
    end

    test "DELETE /snatches/:id/hnr clears HnR flag", %{snatch: snatch} do
      conn = conn(:delete, "/snatches/#{snatch.id}/hnr") |> call()

      assert conn.status == 200
      assert json_body(conn)["data"]["hnr"] == false
    end
  end

  describe "HnR endpoints" do
    test "GET /hnr returns list of HnR snatches" do
      conn = conn(:get, "/hnr") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert is_list(body["data"])
    end

    test "POST /hnr/check triggers HnR detection" do
      conn = conn(:post, "/hnr/check") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert body["message"] =~ "triggered"
    end
  end

  describe "bonus endpoints" do
    test "POST /bonus/calculate triggers bonus calculation" do
      conn = conn(:post, "/bonus/calculate") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert body["message"] =~ "triggered"
    end
  end

  describe "system endpoints" do
    test "GET /stats returns tracker statistics" do
      conn = conn(:get, "/stats") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert Map.has_key?(body["data"], "users")
      assert Map.has_key?(body["data"], "torrents")
    end

    test "POST /stats/flush triggers stats buffer flush" do
      conn = conn(:post, "/stats/flush") |> call()

      assert conn.status == 200
      assert json_body(conn)["success"] == true
    end

    test "GET /swarms returns list of active swarms" do
      conn = conn(:get, "/swarms") |> call()

      assert conn.status == 200
      body = json_body(conn)
      assert body["success"] == true
      assert is_list(body["data"])
    end
  end
end
