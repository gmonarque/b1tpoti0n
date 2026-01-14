defmodule B1tpoti0n.Network.AdminRouter do
  @moduledoc """
  REST API router for admin operations.
  All endpoints require X-Admin-Token header authentication.

  ## Endpoints

  ### Stats
  - GET /stats - Get tracker statistics

  ### Users
  - GET /users - List all users
  - GET /users/search?q=xxx - Search users by passkey
  - POST /users - Create a new user
  - GET /users/:id - Get user by ID
  - DELETE /users/:id - Delete user
  - POST /users/:id/reset - Reset user's passkey
  - PUT /users/:id/stats - Update user stats (uploaded/downloaded)
  - PUT /users/:id/leech - Toggle user can_leech status
  - POST /users/:id/warnings/clear - Clear HnR warnings

  ### Torrents
  - GET /torrents - List all torrents
  - POST /torrents - Register a torrent
  - GET /torrents/:id - Get torrent by ID or info_hash
  - DELETE /torrents/:id - Delete torrent
  - PUT /torrents/:id/stats - Manually update torrent stats

  ### Whitelist
  - GET /whitelist - List whitelisted clients
  - POST /whitelist - Add client to whitelist
  - DELETE /whitelist/:prefix - Remove client from whitelist

  ### Rate Limits
  - GET /ratelimits - Get rate limiter statistics
  - GET /ratelimits/:ip - Get rate limit state for IP
  - DELETE /ratelimits/:ip - Reset rate limits for IP
  - DELETE /ratelimits/:ip/:type - Reset specific limit type

  ### IP Bans
  - GET /bans - List all banned IPs
  - GET /bans/active - List only active (non-expired) bans
  - POST /bans - Ban an IP address
  - GET /bans/:ip - Get ban details
  - PUT /bans/:ip - Update ban (reason/duration)
  - DELETE /bans/:ip - Unban an IP address
  - POST /bans/cleanup - Clean up expired bans

  ### Freeleech & Multipliers
  - POST /torrents/:id/freeleech - Enable freeleech
  - DELETE /torrents/:id/freeleech - Disable freeleech
  - PUT /torrents/:id/multipliers - Set upload/download multipliers
  - GET /freeleech - List all freeleech torrents

  ### Bonus Points
  - GET /bonus/stats - Get bonus points calculator statistics
  - POST /bonus/calculate - Trigger manual calculation
  - GET /users/:id/points - Get user's bonus points
  - POST /users/:id/points - Add bonus points to user
  - DELETE /users/:id/points - Remove bonus points from user
  - POST /users/:id/redeem - Redeem points for upload credit

  ### Snatches
  - GET /snatches - List all snatches (with pagination)
  - GET /snatches/:id - Get single snatch details
  - PUT /snatches/:id - Update snatch (seedtime, hnr flag)
  - DELETE /snatches/:id - Delete snatch
  - GET /users/:id/snatches - List user's snatches
  - GET /torrents/:id/snatches - List torrent's snatches

  ### Hit-and-Run
  - GET /hnr - List all HnR violations
  - POST /hnr/check - Trigger manual HnR check
  - DELETE /snatches/:id/hnr - Clear HnR flag on snatch

  ### Peer Verification
  - GET /verification/stats - Get peer verification statistics
  - DELETE /verification/cache - Clear verification cache

  ### System
  - POST /stats/flush - Force flush stats buffer to DB
  - GET /swarms - List active swarm workers
  """
  use Plug.Router

  alias B1tpoti0n.Admin
  alias B1tpoti0n.Network.RateLimiter
  alias B1tpoti0n.Torrents
  alias B1tpoti0n.Snatches
  alias B1tpoti0n.Bonus.Calculator, as: BonusCalculator
  alias B1tpoti0n.Hnr.Detector, as: HnrDetector
  alias B1tpoti0n.Stats.Collector, as: StatsCollector

  plug(:cors)
  plug(:check_ip_whitelist)
  plug(:check_rate_limit)
  plug(:authenticate)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  options _ do
    conn
    |> send_resp(204, "")
  end

  # =============================================================================
  # Stats
  # =============================================================================

  get "/stats" do
    stats = Admin.stats()
    json_response(conn, 200, %{data: stats, success: true})
  end

  # =============================================================================
  # Users
  # =============================================================================

  get "/users" do
    users = Admin.list_users()
    data = Enum.map(users, &serialize_user/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  get "/users/search" do
    query = conn.query_params["q"] || conn.query_params["passkey"] || ""

    if String.length(query) >= 3 do
      users = Admin.search_users(query)
      data = Enum.map(users, &serialize_user/1)
      json_response(conn, 200, %{data: data, count: length(data), success: true})
    else
      json_response(conn, 400, %{
        error: "Search query must be at least 3 characters",
        success: false
      })
    end
  end

  get "/users/passkey/:passkey" do
    case Admin.get_user_by_passkey(passkey) do
      nil ->
        json_response(conn, 404, %{error: "User not found", success: false})

      user ->
        json_response(conn, 200, %{data: serialize_user(user), success: true})
    end
  end

  post "/users" do
    passkey = get_in(conn.body_params, ["passkey"])

    result =
      if passkey do
        Admin.create_user(passkey)
      else
        Admin.create_user()
      end

    case result do
      {:ok, user} ->
        json_response(conn, 201, %{data: serialize_user(user), success: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = format_changeset_errors(changeset)
        json_response(conn, 422, %{error: "Validation failed", details: errors, success: false})

      {:error, message} when is_binary(message) ->
        json_response(conn, 400, %{error: message, success: false})
    end
  end

  get "/users/:id" do
    case parse_id(id) do
      {:ok, user_id} ->
        case Admin.get_user(user_id) do
          nil ->
            json_response(conn, 404, %{error: "User not found", success: false})

          user ->
            json_response(conn, 200, %{data: serialize_user(user), success: true})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  delete "/users/:id" do
    case parse_id(id) do
      {:ok, user_id} ->
        case Admin.delete_user(user_id) do
          {:ok, _user} ->
            json_response(conn, 200, %{success: true, message: "User deleted"})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "User not found", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  post "/users/:id/reset" do
    case parse_id(id) do
      {:ok, user_id} ->
        case Admin.reset_passkey(user_id) do
          {:ok, user} ->
            json_response(conn, 200, %{data: serialize_user(user), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "User not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  put "/users/:id/stats" do
    uploaded = get_in(conn.body_params, ["uploaded"])
    downloaded = get_in(conn.body_params, ["downloaded"])
    operation = get_in(conn.body_params, ["operation"]) || "set"

    if operation not in ["set", "add", "subtract"] do
      json_response(conn, 400, %{
        error: "Invalid operation. Must be: set, add, or subtract",
        success: false
      })
    else
      case parse_id(id) do
        {:ok, user_id} ->
          op = String.to_existing_atom(operation)

          stats =
            [uploaded: uploaded, downloaded: downloaded]
            |> Enum.reject(fn {_, v} -> is_nil(v) end)

          case Admin.update_user_stats(user_id, stats, operation: op) do
            {:ok, user} ->
              json_response(conn, 200, %{data: serialize_user(user), success: true})

            {:error, :not_found} ->
              json_response(conn, 404, %{error: "User not found", success: false})

            {:error, %Ecto.Changeset{} = changeset} ->
              errors = format_changeset_errors(changeset)
              json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
          end

        :error ->
          json_response(conn, 400, %{error: "Invalid user ID", success: false})
      end
    end
  end

  put "/users/:id/leech" do
    can_leech = get_in(conn.body_params, ["can_leech"])

    case parse_id(id) do
      {:ok, user_id} ->
        if is_boolean(can_leech) do
          case Admin.update_user_can_leech(user_id, can_leech) do
            {:ok, user} ->
              json_response(conn, 200, %{data: serialize_user(user), success: true})

            {:error, :not_found} ->
              json_response(conn, 404, %{error: "User not found", success: false})

            {:error, %Ecto.Changeset{} = changeset} ->
              errors = format_changeset_errors(changeset)
              json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
          end
        else
          json_response(conn, 400, %{error: "can_leech must be a boolean", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  post "/users/:id/warnings/clear" do
    case parse_id(id) do
      {:ok, user_id} ->
        case Admin.clear_user_warnings(user_id) do
          {:ok, user} ->
            json_response(conn, 200, %{
              data: serialize_user(user),
              success: true,
              message: "HnR warnings cleared and leeching re-enabled"
            })

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "User not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  # =============================================================================
  # Torrents
  # =============================================================================

  get "/torrents" do
    torrents = Admin.list_torrents()
    data = Enum.map(torrents, &serialize_torrent/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  post "/torrents" do
    info_hash = get_in(conn.body_params, ["info_hash"])

    if info_hash && is_binary(info_hash) && byte_size(info_hash) == 40 do
      case Admin.register_torrent(info_hash) do
        {:ok, torrent} ->
          json_response(conn, 201, %{data: serialize_torrent(torrent), success: true})

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = format_changeset_errors(changeset)
          json_response(conn, 422, %{error: "Validation failed", details: errors, success: false})

        {:error, reason} ->
          json_response(conn, 400, %{error: to_string(reason), success: false})
      end
    else
      json_response(conn, 400, %{
        error: "Missing or invalid info_hash (must be 40-character hex string)",
        success: false
      })
    end
  end

  get "/torrents/:id" do
    result =
      case parse_id(id) do
        {:ok, torrent_id} -> Admin.get_torrent_by_id(torrent_id)
        :error -> Admin.get_torrent(id)
      end

    case result do
      nil ->
        json_response(conn, 404, %{error: "Torrent not found", success: false})

      torrent ->
        json_response(conn, 200, %{data: serialize_torrent(torrent), success: true})
    end
  end

  delete "/torrents/:id" do
    case parse_id(id) do
      {:ok, torrent_id} ->
        case Admin.delete_torrent(torrent_id) do
          {:ok, _torrent} ->
            json_response(conn, 200, %{success: true, message: "Torrent deleted"})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Torrent not found", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  put "/torrents/:id/stats" do
    seeders = get_in(conn.body_params, ["seeders"])
    leechers = get_in(conn.body_params, ["leechers"])
    completed = get_in(conn.body_params, ["completed"])

    case parse_id(id) do
      {:ok, torrent_id} ->
        stats =
          []
          |> then(fn s -> if seeders, do: Keyword.put(s, :seeders, seeders), else: s end)
          |> then(fn s -> if leechers, do: Keyword.put(s, :leechers, leechers), else: s end)
          |> then(fn s -> if completed, do: Keyword.put(s, :completed, completed), else: s end)

        case Torrents.set_stats(torrent_id, stats) do
          {:ok, torrent} ->
            json_response(conn, 200, %{data: serialize_torrent(torrent), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Torrent not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  # =============================================================================
  # Freeleech & Multipliers
  # =============================================================================

  get "/freeleech" do
    torrents = Torrents.list_freeleech()
    data = Enum.map(torrents, &serialize_torrent/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  post "/torrents/:id/freeleech" do
    duration = get_in(conn.body_params, ["duration"])

    case parse_id(id) do
      {:ok, torrent_id} ->
        until = parse_duration(duration)

        case Torrents.set_freeleech(torrent_id, true, until) do
          {:ok, torrent} ->
            json_response(conn, 200, %{data: serialize_torrent(torrent), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Torrent not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  delete "/torrents/:id/freeleech" do
    case parse_id(id) do
      {:ok, torrent_id} ->
        case Torrents.set_freeleech(torrent_id, false) do
          {:ok, torrent} ->
            json_response(conn, 200, %{data: serialize_torrent(torrent), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Torrent not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  put "/torrents/:id/multipliers" do
    upload_mult = get_in(conn.body_params, ["upload_multiplier"]) || 1.0
    download_mult = get_in(conn.body_params, ["download_multiplier"]) || 1.0

    case parse_id(id) do
      {:ok, torrent_id} ->
        case Torrents.set_multipliers(torrent_id, upload_mult, download_mult) do
          {:ok, torrent} ->
            json_response(conn, 200, %{data: serialize_torrent(torrent), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Torrent not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  # =============================================================================
  # Whitelist
  # =============================================================================

  get "/whitelist" do
    clients = Admin.list_whitelist()
    data = Enum.map(clients, &serialize_whitelist/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  post "/whitelist" do
    prefix = get_in(conn.body_params, ["prefix"])
    name = get_in(conn.body_params, ["name"])

    if prefix && name do
      case Admin.add_to_whitelist(prefix, name) do
        {:ok, entry} ->
          json_response(conn, 201, %{data: serialize_whitelist(entry), success: true})

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = format_changeset_errors(changeset)
          json_response(conn, 422, %{error: "Validation failed", details: errors, success: false})
      end
    else
      json_response(conn, 400, %{
        error: "Missing required fields: prefix and name",
        success: false
      })
    end
  end

  delete "/whitelist/:prefix" do
    case Admin.remove_from_whitelist(prefix) do
      {:ok, _entry} ->
        json_response(conn, 200, %{success: true, message: "Client removed from whitelist"})

      {:error, :not_found} ->
        json_response(conn, 404, %{error: "Client not found in whitelist", success: false})
    end
  end

  # =============================================================================
  # Rate Limits
  # =============================================================================

  get "/ratelimits" do
    stats = RateLimiter.stats()
    json_response(conn, 200, %{data: stats, success: true})
  end

  get "/ratelimits/:ip" do
    state = RateLimiter.get_state(ip)
    json_response(conn, 200, %{data: %{ip: ip, limits: state}, success: true})
  end

  delete "/ratelimits/:ip" do
    RateLimiter.reset(ip)
    json_response(conn, 200, %{success: true, message: "Rate limits reset for #{ip}"})
  end

  # =============================================================================
  # IP Bans
  # =============================================================================

  get "/bans" do
    bans = Admin.list_bans()
    data = Enum.map(bans, &serialize_ban/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  get "/bans/active" do
    bans = Admin.list_active_bans()
    data = Enum.map(bans, &serialize_ban/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  post "/bans/cleanup" do
    {count, _} = Admin.cleanup_expired_bans()
    json_response(conn, 200, %{success: true, message: "Cleaned up #{count} expired bans"})
  end

  post "/bans" do
    ip = get_in(conn.body_params, ["ip"])
    reason = get_in(conn.body_params, ["reason"])
    duration = get_in(conn.body_params, ["duration"])

    if ip && reason do
      opts = if duration, do: [duration: duration], else: []

      case Admin.ban_ip(ip, reason, opts) do
        {:ok, ban} ->
          json_response(conn, 201, %{data: serialize_ban(ban), success: true})

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = format_changeset_errors(changeset)
          json_response(conn, 422, %{error: "Validation failed", details: errors, success: false})
      end
    else
      json_response(conn, 400, %{
        error: "Missing required fields: ip and reason",
        success: false
      })
    end
  end

  get "/bans/:ip" do
    case Admin.get_ban(ip) do
      nil ->
        json_response(conn, 404, %{error: "Ban not found", success: false})

      ban ->
        json_response(conn, 200, %{data: serialize_ban(ban), success: true})
    end
  end

  put "/bans/:ip" do
    reason = get_in(conn.body_params, ["reason"])
    duration = get_in(conn.body_params, ["duration"])

    opts =
      []
      |> then(fn o -> if reason, do: Keyword.put(o, :reason, reason), else: o end)
      |> then(fn o ->
        if Map.has_key?(conn.body_params, "duration"),
          do: Keyword.put(o, :duration, duration),
          else: o
      end)

    case Admin.update_ban(ip, opts) do
      {:ok, ban} ->
        json_response(conn, 200, %{data: serialize_ban(ban), success: true})

      {:error, :not_found} ->
        json_response(conn, 404, %{error: "Ban not found", success: false})

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = format_changeset_errors(changeset)
        json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
    end
  end

  delete "/bans/:ip" do
    case Admin.unban_ip(ip) do
      {:ok, _} ->
        json_response(conn, 200, %{success: true, message: "IP unbanned"})

      {:error, :not_found} ->
        json_response(conn, 404, %{error: "Ban not found", success: false})
    end
  end

  # =============================================================================
  # Bonus Points
  # =============================================================================

  get "/bonus/stats" do
    stats = BonusCalculator.stats()
    json_response(conn, 200, %{data: stats, success: true})
  end

  post "/bonus/calculate" do
    BonusCalculator.calculate_now()
    json_response(conn, 200, %{success: true, message: "Bonus calculation triggered"})
  end

  get "/users/:id/points" do
    case parse_id(id) do
      {:ok, user_id} ->
        case BonusCalculator.get_points(user_id) do
          {:ok, points} ->
            json_response(conn, 200, %{
              data: %{user_id: user_id, bonus_points: points},
              success: true
            })

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "User not found", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  post "/users/:id/points" do
    points = get_in(conn.body_params, ["points"])

    case parse_id(id) do
      {:ok, user_id} ->
        case points do
          nil ->
            json_response(conn, 400, %{error: "Missing required field: points", success: false})

          p when is_number(p) and p > 0 ->
            case BonusCalculator.add_points(user_id, p) do
              :ok ->
                {:ok, new_points} = BonusCalculator.get_points(user_id)

                json_response(conn, 200, %{
                  data: %{user_id: user_id, bonus_points: new_points},
                  success: true
                })

              {:error, :not_found} ->
                json_response(conn, 404, %{error: "User not found", success: false})
            end

          _ ->
            json_response(conn, 400, %{error: "Points must be a positive number", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  delete "/users/:id/points" do
    points = get_in(conn.body_params, ["points"])

    case parse_id(id) do
      {:ok, user_id} ->
        case points do
          nil ->
            json_response(conn, 400, %{error: "Missing required field: points", success: false})

          p when is_number(p) and p > 0 ->
            case BonusCalculator.remove_points(user_id, p) do
              :ok ->
                {:ok, new_points} = BonusCalculator.get_points(user_id)

                json_response(conn, 200, %{
                  data: %{user_id: user_id, bonus_points: new_points},
                  success: true
                })

              {:error, :not_found} ->
                json_response(conn, 404, %{error: "User not found", success: false})

              {:error, :insufficient_points} ->
                json_response(conn, 400, %{error: "Insufficient bonus points", success: false})
            end

          _ ->
            json_response(conn, 400, %{error: "Points must be a positive number", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  post "/users/:id/redeem" do
    points = get_in(conn.body_params, ["points"])
    config = Application.get_env(:b1tpoti0n, :bonus_points, [])
    default_rate = Keyword.get(config, :conversion_rate, 1_000_000_000)
    conversion_rate = get_in(conn.body_params, ["conversion_rate"]) || default_rate

    case parse_id(id) do
      {:ok, user_id} ->
        case points do
          nil ->
            json_response(conn, 400, %{error: "Missing required field: points", success: false})

          p when is_number(p) and p > 0 ->
            case BonusCalculator.redeem_points(user_id, p, conversion_rate) do
              {:ok, upload_credit} ->
                {:ok, new_points} = BonusCalculator.get_points(user_id)

                json_response(conn, 200, %{
                  data: %{
                    user_id: user_id,
                    bonus_points: new_points,
                    upload_credit: upload_credit,
                    upload_credit_formatted: format_bytes(upload_credit)
                  },
                  success: true
                })

              {:error, :not_found} ->
                json_response(conn, 404, %{error: "User not found", success: false})

              {:error, :insufficient_points} ->
                json_response(conn, 400, %{error: "Insufficient bonus points", success: false})
            end

          _ ->
            json_response(conn, 400, %{error: "Points must be a positive number", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  # =============================================================================
  # Snatches
  # =============================================================================

  get "/users/:id/snatches" do
    case parse_id(id) do
      {:ok, user_id} ->
        snatches = Snatches.list_user_snatches(user_id)
        data = Enum.map(snatches, &serialize_snatch/1)
        json_response(conn, 200, %{data: data, count: length(data), success: true})

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  get "/users/:id/peers" do
    case parse_id(id) do
      {:ok, user_id} ->
        peers = Admin.get_user_active_peers(user_id)
        json_response(conn, 200, %{data: peers, count: length(peers), success: true})

      :error ->
        json_response(conn, 400, %{error: "Invalid user ID", success: false})
    end
  end

  get "/torrents/:id/snatches" do
    case parse_id(id) do
      {:ok, torrent_id} ->
        snatches = Snatches.list_torrent_snatches(torrent_id)
        data = Enum.map(snatches, &serialize_snatch/1)
        json_response(conn, 200, %{data: data, count: length(data), success: true})

      :error ->
        json_response(conn, 400, %{error: "Invalid torrent ID", success: false})
    end
  end

  get "/snatches/:id" do
    case parse_id(id) do
      {:ok, snatch_id} ->
        case Snatches.get_snatch_by_id(snatch_id) do
          nil ->
            json_response(conn, 404, %{error: "Snatch not found", success: false})

          snatch ->
            json_response(conn, 200, %{data: serialize_snatch(snatch), success: true})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid snatch ID", success: false})
    end
  end

  put "/snatches/:id" do
    seedtime = get_in(conn.body_params, ["seedtime"])
    hnr = get_in(conn.body_params, ["hnr"])

    case parse_id(id) do
      {:ok, snatch_id} ->
        opts =
          []
          |> then(fn o -> if seedtime, do: Keyword.put(o, :seedtime, seedtime), else: o end)
          |> then(fn o -> if is_boolean(hnr), do: Keyword.put(o, :hnr, hnr), else: o end)

        case Snatches.update_snatch(snatch_id, opts) do
          {:ok, snatch} ->
            json_response(conn, 200, %{data: serialize_snatch(snatch), success: true})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Snatch not found", success: false})

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = format_changeset_errors(changeset)
            json_response(conn, 422, %{error: "Update failed", details: errors, success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid snatch ID", success: false})
    end
  end

  delete "/snatches/:id" do
    case parse_id(id) do
      {:ok, snatch_id} ->
        case Snatches.delete_snatch(snatch_id) do
          {:ok, _} ->
            json_response(conn, 200, %{success: true, message: "Snatch deleted"})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Snatch not found", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid snatch ID", success: false})
    end
  end

  delete "/snatches/:id/hnr" do
    case parse_id(id) do
      {:ok, snatch_id} ->
        case Snatches.clear_hnr(snatch_id) do
          {:ok, snatch} ->
            json_response(conn, 200, %{
              data: serialize_snatch(snatch),
              success: true,
              message: "HnR flag cleared"
            })

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "Snatch not found", success: false})
        end

      :error ->
        json_response(conn, 400, %{error: "Invalid snatch ID", success: false})
    end
  end

  # =============================================================================
  # Hit-and-Run
  # =============================================================================

  get "/hnr" do
    snatches = Snatches.list_hnr_snatches()
    data = Enum.map(snatches, &serialize_snatch/1)
    json_response(conn, 200, %{data: data, count: length(data), success: true})
  end

  post "/hnr/check" do
    HnrDetector.check_now()
    json_response(conn, 200, %{success: true, message: "HnR check triggered"})
  end

  # =============================================================================
  # System
  # =============================================================================

  post "/stats/flush" do
    StatsCollector.force_flush()
    json_response(conn, 200, %{success: true, message: "Stats buffer flushed to database"})
  end

  get "/swarms" do
    workers = B1tpoti0n.Swarm.list_workers()

    data =
      Enum.take(workers, 100)
      |> Enum.map(fn {info_hash, pid} ->
        stats =
          try do
            B1tpoti0n.Swarm.Worker.get_stats(pid)
          catch
            _, _ -> {0, 0, 0}
          end

        {seeders, completed, leechers} = stats

        %{
          info_hash: Base.encode16(info_hash, case: :lower),
          seeders: seeders,
          leechers: leechers,
          completed: completed,
          pid: inspect(pid)
        }
      end)

    json_response(conn, 200, %{
      data: data,
      count: length(data),
      total: length(workers),
      success: true
    })
  end

  # =============================================================================
  # Peer Verification
  # =============================================================================

  get "/verification/stats" do
    stats = B1tpoti0n.Network.PeerVerifier.stats()
    json_response(conn, 200, %{data: stats, success: true})
  end

  delete "/verification/cache" do
    :ok = B1tpoti0n.Network.PeerVerifier.clear_cache()
    json_response(conn, 200, %{success: true, message: "Verification cache cleared"})
  end

  # =============================================================================
  # Catch-all
  # =============================================================================

  match _ do
    json_response(conn, 404, %{error: "Not found", success: false})
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp cors(conn, _opts) do
    origin = get_cors_origin(conn)

    conn
    |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
    |> Plug.Conn.put_resp_header(
      "access-control-allow-methods",
      "GET, POST, PUT, DELETE, OPTIONS"
    )
    |> Plug.Conn.put_resp_header("access-control-allow-headers", "content-type, x-admin-token")
  end

  defp get_cors_origin(conn) do
    config = Application.get_env(:b1tpoti0n, :cors_origins, "*")
    request_origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

    case config do
      "*" ->
        "*"

      origins when is_list(origins) ->
        if request_origin && request_origin in origins do
          request_origin
        else
          List.first(origins) || ""
        end

      origin when is_binary(origin) ->
        origin
    end
  end

  defp check_rate_limit(conn, _opts) do
    if conn.method == "OPTIONS" do
      conn
    else
      client_ip = get_client_ip(conn)

      case RateLimiter.check(client_ip, :admin_api) do
        :ok ->
          conn

        {:error, :rate_limited, retry_after_ms} ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
          |> json_response(429, %{
            error: "Rate limit exceeded",
            retry_after: div(retry_after_ms, 1000) + 1,
            success: false
          })
          |> Plug.Conn.halt()
      end
    end
  end

  defp check_ip_whitelist(conn, _opts) do
    if conn.method == "OPTIONS" do
      conn
    else
      whitelist = Application.get_env(:b1tpoti0n, :admin_api_ip_whitelist, [])

      if whitelist == [] do
        conn
      else
        client_ip = get_client_ip(conn)

        if client_ip in whitelist do
          conn
        else
          conn
          |> json_response(404, %{error: "Not found", success: false})
          |> Plug.Conn.halt()
        end
      end
    end
  end

  defp get_client_ip(conn) do
    trust_xff = Application.get_env(:b1tpoti0n, :trust_x_forwarded_for, false)

    if trust_xff do
      forwarded_for =
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> List.first()

      case forwarded_for do
        nil ->
          conn.remote_ip |> :inet.ntoa() |> to_string()

        header ->
          header
          |> String.split(",")
          |> List.first()
          |> String.trim()
      end
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp authenticate(conn, _opts) do
    if conn.method == "OPTIONS" do
      conn
    else
      admin_token = Application.get_env(:b1tpoti0n, :admin_token)

      if is_nil(admin_token) or admin_token == "" do
        conn
        |> json_response(404, %{error: "Not found", success: false})
        |> Plug.Conn.halt()
      else
        request_token =
          conn
          |> Plug.Conn.get_req_header("x-admin-token")
          |> List.first()

        if request_token && Plug.Crypto.secure_compare(request_token, admin_token) do
          conn
        else
          conn
          |> json_response(401, %{error: "Unauthorized", success: false})
          |> Plug.Conn.halt()
        end
      end
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp serialize_user(user) do
    %{
      id: user.id,
      passkey: user.passkey,
      uploaded: user.uploaded,
      downloaded: user.downloaded,
      bonus_points: Map.get(user, :bonus_points, 0.0),
      hnr_warnings: Map.get(user, :hnr_warnings, 0),
      can_leech: Map.get(user, :can_leech, true),
      created_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end

  defp serialize_torrent(torrent) do
    %{
      id: torrent.id,
      info_hash: Base.encode16(torrent.info_hash, case: :lower),
      seeders: torrent.seeders,
      leechers: torrent.leechers,
      completed: torrent.completed,
      freeleech: Map.get(torrent, :freeleech, false),
      freeleech_until: Map.get(torrent, :freeleech_until),
      upload_multiplier: Map.get(torrent, :upload_multiplier, 1.0),
      download_multiplier: Map.get(torrent, :download_multiplier, 1.0),
      created_at: torrent.inserted_at,
      updated_at: torrent.updated_at
    }
  end

  defp serialize_whitelist(entry) do
    %{
      id: entry.id,
      prefix: entry.client_prefix,
      name: entry.name,
      created_at: entry.inserted_at
    }
  end

  defp serialize_ban(ban) do
    %{
      id: ban.id,
      ip: ban.ip,
      reason: ban.reason,
      expires_at: ban.expires_at,
      created_at: ban.inserted_at
    }
  end

  defp serialize_snatch(snatch) do
    %{
      id: snatch.id,
      user_id: snatch.user_id,
      torrent_id: snatch.torrent_id,
      completed_at: snatch.completed_at,
      seedtime: snatch.seedtime,
      seedtime_hours: Float.round(snatch.seedtime / 3600, 2),
      last_announce_at: snatch.last_announce_at,
      hnr: snatch.hnr
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_bytes(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 2)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"

  defp parse_duration(nil), do: nil

  defp parse_duration(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.add(DateTime.utc_now(), seconds, :second)
  end

  defp parse_duration(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {int, ""} -> parse_duration(int)
      _ -> nil
    end
  end

  defp parse_duration(_), do: nil
end
