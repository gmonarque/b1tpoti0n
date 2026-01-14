defmodule B1tpoti0n.Network.UdpHandler do
  @moduledoc """
  Handles UDP tracker protocol requests (BEP 15).
  """
  require Logger

  alias B1tpoti0n.Core.UdpProtocol
  alias B1tpoti0n.Network.UdpServer
  alias B1tpoti0n.Network.RateLimiter
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Swarm

  @doc """
  Handle an incoming UDP packet.
  Returns response binary or nil if no response should be sent.
  """
  @spec handle_packet(binary(), tuple()) :: binary() | nil
  def handle_packet(data, client_ip) do
    client_ip_string = ip_to_string(client_ip)

    # Check if banned
    case Manager.check_banned(client_ip_string) do
      {:banned, reason} ->
        Logger.debug("UDP request from banned IP #{client_ip_string}: #{reason}")
        nil

      :ok ->
        process_packet(data, client_ip, client_ip_string)
    end
  end

  defp process_packet(data, client_ip, client_ip_string) do
    case UdpProtocol.parse_request(data) do
      {:ok, :connect, request} ->
        handle_connect(request, client_ip, client_ip_string)

      {:ok, :announce, request} ->
        handle_announce(request, client_ip, client_ip_string)

      {:ok, :scrape, request} ->
        handle_scrape(request, client_ip, client_ip_string)

      {:error, reason} ->
        Logger.debug("UDP parse error: #{reason}")
        nil
    end
  end

  defp handle_connect(%{transaction_id: transaction_id}, client_ip, client_ip_string) do
    # Rate limit connect requests
    case RateLimiter.check(client_ip_string, :announce) do
      :ok ->
        # SECURITY: Connection ID is bound to client IP
        case UdpServer.new_connection(client_ip) do
          {:ok, connection_id} ->
            B1tpoti0n.Metrics.announce_stop(%{event: "udp_connect"}, 0)
            UdpProtocol.encode_connect_response(transaction_id, connection_id)

          {:error, :too_many_connections} ->
            Logger.warning("UDP connection limit reached, rejecting #{client_ip_string}")
            # SECURITY: Generic error to prevent fingerprinting
            UdpProtocol.encode_error_response(transaction_id, "Try again later")
        end

      {:error, :rate_limited, _} ->
        B1tpoti0n.Metrics.error(:rate_limited)
        UdpProtocol.encode_error_response(transaction_id, "Rate limited")
    end
  end

  defp handle_announce(request, client_ip, client_ip_string) do
    start_time = System.monotonic_time(:millisecond)
    %{transaction_id: transaction_id, connection_id: connection_id} = request

    # SECURITY: Validate connection_id is bound to this client IP
    unless UdpServer.valid_connection?(connection_id, client_ip) do
      return_error(transaction_id, "Invalid connection_id")
    else
      # Rate limit
      case RateLimiter.check(client_ip_string, :announce) do
        :ok ->
          process_announce(request, client_ip, start_time)

        {:error, :rate_limited, _} ->
          B1tpoti0n.Metrics.error(:rate_limited)
          UdpProtocol.encode_error_response(transaction_id, "Rate limited")
      end
    end
  end

  defp process_announce(request, client_ip, start_time) do
    %{
      transaction_id: transaction_id,
      info_hash: info_hash,
      peer_id: peer_id,
      downloaded: downloaded,
      left: left,
      uploaded: uploaded,
      event: event,
      num_want: num_want,
      port: port
    } = request

    # Check client whitelist
    unless Manager.valid_client?(peer_id) do
      B1tpoti0n.Metrics.error(:client_not_whitelisted)
      # SECURITY: Generic error to prevent fingerprinting
      return_error(transaction_id, "Not authorized")
    else
      # Get or start worker
      case Swarm.get_or_start_worker(info_hash) do
        {:ok, worker_pid} ->
          # Prepare peer data (UDP doesn't have passkey auth by default)
          peer_data = %{
            user_id: nil,
            ip: client_ip,
            port: port,
            left: left,
            peer_id: peer_id,
            event: UdpProtocol.event_to_string(event),
            uploaded: uploaded,
            downloaded: downloaded
          }

          # Announce to swarm (UDP doesn't use key rotation)
          case Swarm.Worker.announce(worker_pid, peer_data, num_want) do
            {:error, _reason} ->
              # Key validation errors shouldn't happen for UDP since we don't track keys
              return_error(transaction_id, "Announce failed")

            {seeders, leechers, peers, _stats_delta, _announce_key} ->
              # Get interval with jitter to prevent thundering herd
              base_interval = Application.get_env(:b1tpoti0n, :announce_interval, 1800)
              jitter_percent = Application.get_env(:b1tpoti0n, :announce_jitter, 0.1)
              interval = B1tpoti0n.Core.Bencode.apply_jitter(base_interval, jitter_percent)

              # Record metrics
              duration = System.monotonic_time(:millisecond) - start_time
              event_str = UdpProtocol.event_to_string(event) || "update"
              B1tpoti0n.Metrics.announce_stop(%{event: "udp_#{event_str}"}, duration)

              # Encode response
              UdpProtocol.encode_announce_response(
                transaction_id,
                interval,
                leechers,
                seeders,
                peers
              )
          end

        {:error, :not_registered} ->
          B1tpoti0n.Metrics.error(:not_registered)
          # SECURITY: Generic error to prevent fingerprinting
          return_error(transaction_id, "Not found")
      end
    end
  end

  defp handle_scrape(request, client_ip, client_ip_string) do
    start_time = System.monotonic_time(:millisecond)

    %{transaction_id: transaction_id, connection_id: connection_id, info_hashes: info_hashes} =
      request

    # SECURITY: Validate connection_id is bound to this client IP
    unless UdpServer.valid_connection?(connection_id, client_ip) do
      return_error(transaction_id, "Invalid connection_id")
    else
      # Rate limit
      case RateLimiter.check(client_ip_string, :scrape) do
        :ok ->
          # Get stats for each info_hash
          stats =
            Enum.map(info_hashes, fn info_hash ->
              case Swarm.get_worker(info_hash) do
                {:ok, worker_pid} ->
                  Swarm.Worker.get_stats(worker_pid)

                {:error, _} ->
                  {0, 0, 0}
              end
            end)

          duration = System.monotonic_time(:millisecond) - start_time
          B1tpoti0n.Metrics.scrape_stop(%{protocol: "udp"}, duration)

          UdpProtocol.encode_scrape_response(transaction_id, stats)

        {:error, :rate_limited, _} ->
          B1tpoti0n.Metrics.error(:rate_limited)
          UdpProtocol.encode_error_response(transaction_id, "Rate limited")
      end
    end
  end

  defp return_error(transaction_id, message) do
    UdpProtocol.encode_error_response(transaction_id, message)
  end

  defp ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp ip_to_string({a, b, c, d, e, f, g, h}) do
    :inet.ntoa({a, b, c, d, e, f, g, h}) |> List.to_string()
  end

  defp ip_to_string(ip) when is_binary(ip), do: ip
end
