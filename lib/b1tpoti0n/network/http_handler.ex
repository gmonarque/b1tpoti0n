defmodule B1tpoti0n.Network.HttpHandler do
  @moduledoc """
  Business logic for HTTP tracker requests.
  Handles announce and scrape processing.
  """

  @passkey_length 32

  alias B1tpoti0n.Core.{Parser, Bencode}
  alias B1tpoti0n.Store.Manager
  alias B1tpoti0n.Swarm
  alias B1tpoti0n.Stats
  alias B1tpoti0n.Torrents
  alias B1tpoti0n.Snatches

  @doc """
  Process an HTTP announce request.

  ## Parameters
  - query_params: Map of query string parameters
  - passkey: The passkey from the URL path
  - remote_ip: The client's IP address tuple

  ## Returns
  - {:ok, bencoded_response} on success
  - {:error, reason} on failure
  """
  @spec process_announce(map(), String.t() | nil, tuple()) ::
          {:ok, binary()} | {:error, String.t()}
  def process_announce(query_params, passkey, remote_ip) do
    base_interval = Application.get_env(:b1tpoti0n, :announce_interval, 1800)
    jitter_percent = Application.get_env(:b1tpoti0n, :announce_jitter, 0.1)
    interval = Bencode.apply_jitter(base_interval, jitter_percent)

    with {:ok, user_id} <- validate_passkey(passkey),
         {:ok, request} <- Parser.parse_http_announce(query_params, passkey, remote_ip),
         true <- Manager.valid_client?(request.peer_id) || {:error, "Not authorized"},
         :ok <- check_leech_allowed(user_id, request.left),
         {:ok, worker_pid} <- Swarm.get_or_start_worker(request.info_hash) do
      peer_data = %{
        user_id: user_id,
        ip: remote_ip,
        port: request.port,
        left: request.left,
        peer_id: request.peer_id,
        event: request.event,
        uploaded: request.uploaded,
        downloaded: request.downloaded,
        key: Map.get(request, :key)
      }

      announce_result = Swarm.Worker.announce(worker_pid, peer_data, request.num_want)

      case announce_result do
        {:error, :key_required} ->
          {:error, "Invalid request parameters"}

        {:error, :invalid_key} ->
          {:error, "Session expired"}

        {seeders, leechers, peers, stats_delta, announce_key} ->
          process_announce_success(
            user_id,
            request,
            seeders,
            leechers,
            peers,
            stats_delta,
            announce_key,
            interval
          )
      end
    else
      {:error, :not_registered} ->
        {:error, "Unregistered torrent"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      false ->
        {:error, "Not authorized"}
    end
  end

  defp process_announce_success(
         user_id,
         request,
         seeders,
         leechers,
         peers,
         stats_delta,
         announce_key,
         interval
       ) do
    torrent = Torrents.get_by_info_hash(request.info_hash)

    if stats_delta.uploaded > 0 or stats_delta.downloaded > 0 do
      case torrent do
        nil ->
          Stats.Buffer.record_transfer(user_id, stats_delta.uploaded, stats_delta.downloaded)

        t ->
          settings = Torrents.get_settings(t)
          adjusted_upload = trunc(stats_delta.uploaded * settings.upload_multiplier)
          adjusted_download = trunc(stats_delta.downloaded * settings.download_multiplier)
          Stats.Buffer.record_transfer(user_id, adjusted_upload, adjusted_download)
      end
    end

    if torrent do
      case request.event do
        :completed ->
          Snatches.record_snatch(user_id, torrent.id)

        _ when request.left == 0 ->
          Snatches.update_seedtime(user_id, torrent.id)

        _ ->
          :ok
      end
    end

    compact = Map.get(request, :compact, true)

    response_body =
      Bencode.encode_announce_response(interval, seeders, leechers, peers, compact, announce_key)

    {:ok, response_body}
  end

  @doc """
  Process an HTTP scrape request.

  ## Parameters
  - query_params: Map of query string parameters (may contain multiple info_hash)
  - passkey: The passkey from the URL path

  ## Returns
  - {:ok, response_binary} on success
  - {:error, reason} on failure
  """
  @spec process_scrape(map(), String.t() | nil) :: {:ok, binary()} | {:error, String.t()}
  def process_scrape(query_params, passkey) do
    with {:ok, _user_id} <- validate_passkey(passkey) do
      info_hashes = get_info_hashes(query_params)

      if Enum.empty?(info_hashes) do
        {:error, "No info_hash provided"}
      else
        torrents =
          Enum.map(info_hashes, fn info_hash ->
            {seeders, completed, leechers} =
              case Swarm.lookup_worker(info_hash) do
                {:ok, pid} -> Swarm.Worker.get_stats(pid)
                :error -> {0, 0, 0}
              end

            {info_hash, seeders, completed, leechers}
          end)

        response_body = Bencode.encode_scrape_response(torrents)
        {:ok, response_body}
      end
    end
  end

  # --- Private Helpers ---

  # SECURITY: Use generic error messages to prevent fingerprinting
  @auth_error "Invalid passkey"

  defp validate_passkey(nil) do
    {:error, @auth_error}
  end

  defp validate_passkey(passkey) when byte_size(passkey) != @passkey_length do
    {:error, @auth_error}
  end

  defp validate_passkey(passkey) do
    case Manager.lookup_passkey(passkey) do
      {:ok, user_id} -> {:ok, user_id}
      :error -> {:error, @auth_error}
    end
  end

  @max_scrape_hashes 74

  defp get_info_hashes(params) do
    hashes =
      case Map.get(params, "info_hash") do
        nil ->
          []

        hash when is_binary(hash) and byte_size(hash) == 20 ->
          [hash]

        hash when is_binary(hash) ->
          # Try URL decoding
          decoded = URI.decode(hash)
          if byte_size(decoded) == 20, do: [decoded], else: []

        hashes when is_list(hashes) ->
          Enum.flat_map(hashes, fn h ->
            decoded = if byte_size(h) == 20, do: h, else: URI.decode(h)
            if byte_size(decoded) == 20, do: [decoded], else: []
          end)

        _ ->
          []
      end

    Enum.take(hashes, @max_scrape_hashes)
  end

  defp check_leech_allowed(_user_id, 0), do: :ok

  defp check_leech_allowed(user_id, _left) do
    alias B1tpoti0n.Persistence.Repo
    alias B1tpoti0n.Persistence.Schemas.User

    case Repo.get(User, user_id) do
      nil ->
        # User not found in DB (shouldn't happen if passkey validated)
        :ok

      user ->
        cond do
          not user.can_leech ->
            {:error, "Download not permitted"}

          not ratio_ok?(user) ->
            {:error, "Download not permitted"}

          true ->
            :ok
        end
    end
  end

  defp ratio_ok?(user) do
    min_ratio = Application.get_env(:b1tpoti0n, :min_ratio, 0.3)
    grace_bytes = Application.get_env(:b1tpoti0n, :ratio_grace_bytes, 5_000_000_000)

    required_ratio =
      if user.required_ratio > 0.0, do: user.required_ratio, else: min_ratio

    cond do
      user.downloaded < grace_bytes ->
        true

      user.downloaded == 0 ->
        true

      true ->
        current_ratio = user.uploaded / user.downloaded
        current_ratio >= required_ratio
    end
  end
end
