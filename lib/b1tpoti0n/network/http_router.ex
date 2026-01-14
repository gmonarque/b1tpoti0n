defmodule B1tpoti0n.Network.HttpRouter do
  @moduledoc """
  Plug router for HTTP tracker endpoints.
  All endpoints require passkey authentication (private tracker).

  Endpoints:
  - GET /:passkey/announce - Announce with passkey
  - GET /:passkey/scrape - Scrape with passkey
  - GET /health - Health check
  - GET /stats - Basic stats
  - /admin/* - Admin REST API (see AdminRouter)
  """
  use Plug.Router

  alias B1tpoti0n.Network.HttpHandler
  alias B1tpoti0n.Network.RateLimiter
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Core.Bencode

  plug(Plug.Logger)
  plug(:add_server_header)
  plug(:match)
  plug(:dispatch)

  get "/:passkey/announce" do
    client_ip = get_client_ip_string(conn)
    start_time = System.monotonic_time(:millisecond)

    with :ok <- check_ban(client_ip),
         :ok <- RateLimiter.check(client_ip, :announce) do
      remote_ip = get_remote_ip(conn)
      params = parse_tracker_query(conn.query_string)

      case HttpHandler.process_announce(params, passkey, remote_ip) do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time
          event = Map.get(params, "event", "update")
          B1tpoti0n.Metrics.announce_stop(%{event: event}, duration)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, response)

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          B1tpoti0n.Metrics.error(:announce_failed)
          B1tpoti0n.Metrics.announce_stop(%{event: "error"}, duration)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, Bencode.encode_error(reason))
      end
    else
      {:banned, _reason} ->
        B1tpoti0n.Metrics.error(:banned)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, Bencode.encode_error("Not authorized"))

      {:error, :rate_limited, retry_after_ms} ->
        B1tpoti0n.Metrics.error(:rate_limited)

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
        |> send_resp(200, Bencode.encode_error("Rate limit exceeded"))
    end
  end

  get "/:passkey/scrape" do
    client_ip = get_client_ip_string(conn)
    start_time = System.monotonic_time(:millisecond)

    with :ok <- check_ban(client_ip),
         :ok <- RateLimiter.check(client_ip, :scrape) do
      params = parse_tracker_query(conn.query_string)

      case HttpHandler.process_scrape(params, passkey) do
        {:ok, response} ->
          duration = System.monotonic_time(:millisecond) - start_time
          B1tpoti0n.Metrics.scrape_stop(%{}, duration)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, response)

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          B1tpoti0n.Metrics.error(:scrape_failed)
          B1tpoti0n.Metrics.scrape_stop(%{}, duration)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, Bencode.encode_error(reason))
      end
    else
      {:banned, _reason} ->
        B1tpoti0n.Metrics.error(:banned)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, Bencode.encode_error("Not authorized"))

      {:error, :rate_limited, retry_after_ms} ->
        B1tpoti0n.Metrics.error(:rate_limited)

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
        |> send_resp(200, Bencode.encode_error("Rate limit exceeded"))
    end
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  get "/stats" do
    case check_monitoring_access(conn, :stats_endpoint) do
      :ok ->
        cache_stats = B1tpoti0n.Store.Manager.stats()

        stats = %{
          cache: %{
            users: cache_stats.passkeys,
            blocked: cache_stats.banned_ips
          },
          active_transfers: B1tpoti0n.Swarm.count_workers(),
          total_items: length(B1tpoti0n.Swarm.list_torrents()),
          throttle: RateLimiter.stats()
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(stats))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Not found"}))
    end
  end

  get "/metrics" do
    case check_monitoring_access(conn, :metrics_endpoint) do
      :ok ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4")
        |> send_resp(200, B1tpoti0n.Metrics.export_prometheus())

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not found")
    end
  end

  forward "/admin", to: B1tpoti0n.Network.AdminRouter

  get "/ws" do
    admin_token = Application.get_env(:b1tpoti0n, :admin_token)
    query_params = URI.decode_query(conn.query_string || "")
    request_token = Map.get(query_params, "token")

    authenticated =
      admin_token != nil and
        admin_token != "" and
        request_token != nil and
        Plug.Crypto.secure_compare(request_token, admin_token)

    if authenticated do
      conn
      |> WebSockAdapter.upgrade(
        B1tpoti0n.Network.WebSocketHandler,
        [subscriptions: [:stats]],
        timeout: 60_000
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "Not found"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, Bencode.encode_error("Not found"))
  end

  defp add_server_header(conn, _opts) do
    case Application.get_env(:b1tpoti0n, :server_header, "Tracker/1.0") do
      nil -> conn
      false -> conn
      header when is_binary(header) -> Plug.Conn.put_resp_header(conn, "server", header)
    end
  end

  defp check_monitoring_access(conn, config_key) do
    config = Application.get_env(:b1tpoti0n, config_key, [])
    enabled = Keyword.get(config, :enabled, true)
    require_auth = Keyword.get(config, :require_auth, false)
    ip_whitelist = Keyword.get(config, :ip_whitelist, [])

    cond do
      not enabled ->
        {:error, :disabled}

      ip_whitelist != [] and ip_in_whitelist?(conn, ip_whitelist) ->
        :ok

      require_auth ->
        check_monitoring_auth(conn)

      ip_whitelist == [] ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp check_monitoring_auth(conn) do
    admin_token = Application.get_env(:b1tpoti0n, :admin_token)

    # Get token from header or query param
    header_token =
      case Plug.Conn.get_req_header(conn, "x-admin-token") do
        [token | _] -> token
        [] -> nil
      end

    query_token =
      case conn.query_string do
        "" -> nil
        qs -> Map.get(URI.decode_query(qs), "token")
      end

    request_token = header_token || query_token

    cond do
      is_nil(admin_token) or admin_token == "" ->
        {:error, :unauthorized}

      is_nil(request_token) ->
        {:error, :unauthorized}

      Plug.Crypto.secure_compare(request_token, admin_token) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp ip_in_whitelist?(conn, whitelist) do
    client_ip = get_client_ip_string(conn)
    client_ip in whitelist
  end

  # Parse query string with proper handling of binary params (info_hash, peer_id)
  # URI.decode doesn't work for non-UTF8 binary, so we use custom percent decoding
  defp parse_tracker_query(query_string) when is_binary(query_string) do
    query_string
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          decoded_value = percent_decode(value)
          Map.put(acc, key, decoded_value)

        [key] ->
          Map.put(acc, key, "")

        _ ->
          acc
      end
    end)
  end

  # Custom percent decoder that handles binary data (not just UTF-8)
  defp percent_decode(string) do
    percent_decode(string, <<>>)
  end

  defp percent_decode(<<>>, acc), do: acc

  defp percent_decode(<<?%, hex1, hex2, rest::binary>>, acc) do
    case Integer.parse(<<hex1, hex2>>, 16) do
      {byte, ""} -> percent_decode(rest, <<acc::binary, byte>>)
      _ -> percent_decode(rest, <<acc::binary, ?%, hex1, hex2>>)
    end
  end

  defp percent_decode(<<?+, rest::binary>>, acc) do
    # + is space in query strings
    percent_decode(rest, <<acc::binary, ?\s>>)
  end

  defp percent_decode(<<char, rest::binary>>, acc) do
    percent_decode(rest, <<acc::binary, char>>)
  end

  defp get_remote_ip(conn) do
    trust_xff = Application.get_env(:b1tpoti0n, :trust_x_forwarded_for, false)

    if trust_xff do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded
          |> String.split(",")
          |> List.first()
          |> String.trim()
          |> parse_ip()

        [] ->
          conn.remote_ip
      end
    else
      conn.remote_ip
    end
  end

  defp get_client_ip_string(conn) do
    trust_xff = Application.get_env(:b1tpoti0n, :trust_x_forwarded_for, false)

    if trust_xff do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded
          |> String.split(",")
          |> List.first()
          |> String.trim()

        [] ->
          conn.remote_ip
          |> :inet.ntoa()
          |> to_string()
      end
    else
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp check_ban(ip) do
    Manager.check_banned(ip)
  end
end
