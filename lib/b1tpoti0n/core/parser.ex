defmodule B1tpoti0n.Core.Parser do
  @moduledoc """
  Parser for HTTP tracker protocol (BEP 3).
  Parses query parameters from announce and scrape requests.
  """

  @type event :: :none | :completed | :started | :stopped

  @type announce_request :: %{
          info_hash: binary(),
          peer_id: binary(),
          port: non_neg_integer(),
          uploaded: non_neg_integer(),
          downloaded: non_neg_integer(),
          left: non_neg_integer(),
          event: event(),
          num_want: non_neg_integer(),
          compact: boolean(),
          passkey: String.t() | nil,
          ip: tuple(),
          key: String.t() | nil
        }

  @doc """
  Parse HTTP announce query parameters into an announce request.

  ## Required parameters
  - info_hash: 20-byte torrent identifier
  - peer_id: 20-byte peer identifier
  - port: Port the peer is listening on
  - uploaded: Total bytes uploaded
  - downloaded: Total bytes downloaded
  - left: Bytes remaining to download

  ## Optional parameters
  - event: "started", "stopped", "completed", or empty
  - numwant: Number of peers to return (default: 50)
  - compact: "1" for compact format (default: true)
  """
  @spec parse_http_announce(map(), String.t() | nil, tuple()) ::
          {:ok, announce_request()} | {:error, String.t()}
  def parse_http_announce(params, passkey, remote_ip) do
    with {:ok, info_hash} <- get_binary_param(params, "info_hash", 20),
         {:ok, peer_id} <- get_binary_param(params, "peer_id", 20),
         {:ok, port} <- get_port_param(params, "port"),
         {:ok, uploaded} <- get_integer_param(params, "uploaded"),
         {:ok, downloaded} <- get_integer_param(params, "downloaded"),
         {:ok, left} <- get_integer_param(params, "left") do
      event = parse_event_string(Map.get(params, "event", ""))
      num_want = parse_numwant(Map.get(params, "numwant"))
      compact = Map.get(params, "compact", "1") == "1"
      # Optional tracker key for anti-spoofing
      key = Map.get(params, "key")

      {:ok,
       %{
         info_hash: info_hash,
         peer_id: peer_id,
         port: port,
         uploaded: uploaded,
         downloaded: downloaded,
         left: left,
         event: event,
         num_want: num_want,
         compact: compact,
         passkey: passkey,
         ip: remote_ip,
         key: key
       }}
    end
  end

  # Private helpers

  defp parse_event_string("completed"), do: :completed
  defp parse_event_string("started"), do: :started
  defp parse_event_string("stopped"), do: :stopped
  defp parse_event_string(_), do: :none

  defp normalize_num_want(n) when n > 0 and n <= 200, do: n
  defp normalize_num_want(_), do: 50

  defp parse_numwant(nil), do: 50

  defp parse_numwant(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> normalize_num_want(n)
      _ -> 50
    end
  end

  defp get_binary_param(params, key, expected_size) do
    case Map.get(params, key) do
      nil ->
        {:error, "missing #{key}"}

      value when is_binary(value) and byte_size(value) == expected_size ->
        {:ok, value}

      value when is_binary(value) ->
        {:error, "invalid #{key} length (got #{byte_size(value)}, expected #{expected_size})"}

      _ ->
        {:error, "invalid #{key}"}
    end
  end

  defp get_integer_param(params, key) do
    case Map.get(params, key) do
      nil ->
        {:error, "missing #{key}"}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, "invalid #{key}"}
        end

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        {:error, "invalid #{key}"}
    end
  end

  defp get_port_param(params, key) do
    case Map.get(params, key) do
      nil ->
        {:error, "missing #{key}"}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= 1 and n <= 65535 -> {:ok, n}
          _ -> {:error, "invalid #{key}"}
        end

      value when is_integer(value) and value >= 1 and value <= 65535 ->
        {:ok, value}

      _ ->
        {:error, "invalid #{key}"}
    end
  end
end
