defmodule B1tpoti0n.Core.Bencode do
  @moduledoc """
  Bencoding encoder/decoder for HTTP tracker responses (BEP 3).

  Bencoding format:
  - Strings: <length>:<data>
  - Integers: i<number>e
  - Lists: l<items>e
  - Dictionaries: d<key><value>...e (keys must be sorted)
  """

  @doc """
  Decode a bencoded binary to an Elixir term.

  ## Examples

      iex> Bencode.decode("4:spam")
      "spam"

      iex> Bencode.decode("i42e")
      42

      iex> Bencode.decode("d3:cow3:mooe")
      %{"cow" => "moo"}
  """
  @spec decode(binary()) :: term()
  def decode(data) when is_binary(data) do
    {value, _rest} = decode_value(data)
    value
  end

  defp decode_value(<<"i", rest::binary>>) do
    decode_integer(rest, <<>>)
  end

  defp decode_value(<<"l", rest::binary>>) do
    decode_list(rest, [])
  end

  defp decode_value(<<"d", rest::binary>>) do
    decode_dict(rest, %{})
  end

  defp decode_value(<<digit, _::binary>> = data) when digit in ?0..?9 do
    decode_string(data)
  end

  defp decode_integer(<<"e", rest::binary>>, acc) do
    {String.to_integer(acc), rest}
  end

  defp decode_integer(<<char, rest::binary>>, acc) do
    decode_integer(rest, <<acc::binary, char>>)
  end

  defp decode_list(<<"e", rest::binary>>, acc) do
    {Enum.reverse(acc), rest}
  end

  defp decode_list(data, acc) do
    {value, rest} = decode_value(data)
    decode_list(rest, [value | acc])
  end

  defp decode_dict(<<"e", rest::binary>>, acc) do
    {acc, rest}
  end

  defp decode_dict(data, acc) do
    {key, rest1} = decode_value(data)
    {value, rest2} = decode_value(rest1)
    decode_dict(rest2, Map.put(acc, key, value))
  end

  defp decode_string(data) do
    {length_str, rest1} = split_at_colon(data, <<>>)
    length = String.to_integer(length_str)
    <<string::binary-size(length), rest2::binary>> = rest1
    {string, rest2}
  end

  defp split_at_colon(<<":", rest::binary>>, acc) do
    {acc, rest}
  end

  defp split_at_colon(<<char, rest::binary>>, acc) do
    split_at_colon(rest, <<acc::binary, char>>)
  end

  @doc """
  Apply jitter to an interval to prevent thundering herd.
  Returns an integer interval with ±jitter_percent variation.

  ## Examples

      iex> Bencode.apply_jitter(1800, 0.1) # Returns 1620-1980
      1854
  """
  @spec apply_jitter(non_neg_integer(), float()) :: non_neg_integer()
  def apply_jitter(interval, jitter_percent) when jitter_percent > 0 do
    variation = trunc(interval * jitter_percent)
    # Random value between -variation and +variation
    delta = :rand.uniform(variation * 2 + 1) - variation - 1
    max(1, interval + delta)
  end

  def apply_jitter(interval, _jitter_percent), do: interval

  @doc """
  Encode an Elixir term to bencoded binary.

  ## Examples

      iex> Bencode.encode("spam")
      "4:spam"

      iex> Bencode.encode(42)
      "i42e"

      iex> Bencode.encode(%{"cow" => "moo"})
      "d3:cow3:mooe"
  """
  @spec encode(term()) :: binary()
  def encode(value) when is_binary(value) do
    "#{byte_size(value)}:#{value}"
  end

  def encode(value) when is_integer(value) do
    "i#{value}e"
  end

  def encode(value) when is_list(value) do
    encoded_items = Enum.map_join(value, "", &encode/1)
    "l#{encoded_items}e"
  end

  def encode(value) when is_map(value) do
    encoded_pairs =
      value
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("", fn {k, v} ->
        encode(to_string(k)) <> encode(v)
      end)

    "d#{encoded_pairs}e"
  end

  def encode(value) when is_atom(value) do
    encode(Atom.to_string(value))
  end

  @doc """
  Encode a tracker announce response in bencoded format.

  ## Parameters
  - interval: Seconds between announces
  - seeders: Number of seeders
  - leechers: Number of leechers
  - peers: List of peer maps with :ip and :port keys
  - compact: If true, use compact peer format (BEP 23)
  - tracker_key: Optional announce key for peer anti-spoofing

  For IPv6 support (BEP 7), peers are separated into IPv4 and IPv6 lists.
  IPv4 peers go in "peers" key, IPv6 peers go in "peers6" key.
  """
  @spec encode_announce_response(
          interval :: non_neg_integer(),
          seeders :: non_neg_integer(),
          leechers :: non_neg_integer(),
          peers :: list(),
          compact :: boolean(),
          tracker_key :: binary() | nil
        ) :: binary()
  def encode_announce_response(
        interval,
        seeders,
        leechers,
        peers,
        compact \\ true,
        tracker_key \\ nil
      )

  def encode_announce_response(interval, seeders, leechers, peers, compact, tracker_key) do
    # Separate IPv4 and IPv6 peers
    {ipv4_peers, ipv6_peers} = Enum.split_with(peers, &ipv4_peer?/1)

    response =
      if compact do
        base = %{
          "interval" => interval,
          "complete" => seeders,
          "incomplete" => leechers,
          "peers" => encode_peers_compact_v4(ipv4_peers)
        }

        # Add peers6 key only if there are IPv6 peers (BEP 7)
        base =
          if Enum.empty?(ipv6_peers) do
            base
          else
            Map.put(base, "peers6", encode_peers_compact_v6(ipv6_peers))
          end

        # Add tracker key for anti-spoofing (BEP 7 extension)
        if tracker_key do
          Map.put(base, "tracker id", tracker_key)
        else
          base
        end
      else
        base = %{
          "interval" => interval,
          "complete" => seeders,
          "incomplete" => leechers,
          "peers" => encode_peers_dict(peers)
        }

        if tracker_key do
          Map.put(base, "tracker id", tracker_key)
        else
          base
        end
      end

    encode(response)
  end

  @doc """
  Encode a tracker scrape response in bencoded format.
  """
  @spec encode_scrape_response(list()) :: binary()
  def encode_scrape_response(torrents) do
    files =
      torrents
      |> Enum.into(%{}, fn {info_hash, seeders, completed, leechers} ->
        {info_hash,
         %{
           "complete" => seeders,
           "downloaded" => completed,
           "incomplete" => leechers
         }}
      end)

    encode(%{"files" => files})
  end

  @doc """
  Encode an error response.
  """
  @spec encode_error(String.t()) :: binary()
  def encode_error(message) do
    encode(%{"failure reason" => message})
  end

  # Private helpers

  # Check if peer has IPv4 address
  defp ipv4_peer?(%{ip: {_, _, _, _}}), do: true
  defp ipv4_peer?(%{ip: {_, _, _, _, _, _, _, _}}), do: false

  defp ipv4_peer?(%{ip: ip_string}) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, {_, _, _, _}} -> true
      {:ok, {_, _, _, _, _, _, _, _}} -> false
      _ -> true
    end
  end

  defp ipv4_peer?(_), do: true

  # Compact format IPv4: 6 bytes per peer (4 IP + 2 port)
  defp encode_peers_compact_v4(peers) do
    for peer <- peers, into: <<>> do
      case peer do
        %{ip: {a, b, c, d}, port: port} ->
          <<a::8, b::8, c::8, d::8, port::16>>

        %{ip: ip_string, port: port} when is_binary(ip_string) ->
          case :inet.parse_address(String.to_charlist(ip_string)) do
            {:ok, {a, b, c, d}} -> <<a::8, b::8, c::8, d::8, port::16>>
            _ -> <<>>
          end

        _ ->
          <<>>
      end
    end
  end

  # Compact format IPv6: 18 bytes per peer (16 IP + 2 port)
  defp encode_peers_compact_v6(peers) do
    for peer <- peers, into: <<>> do
      case peer do
        %{ip: {a, b, c, d, e, f, g, h}, port: port} ->
          <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16>>

        %{ip: ip_string, port: port} when is_binary(ip_string) ->
          case :inet.parse_address(String.to_charlist(ip_string)) do
            {:ok, {a, b, c, d, e, f, g, h}} ->
              <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16>>

            _ ->
              <<>>
          end

        _ ->
          <<>>
      end
    end
  end

  # Dictionary format: list of maps with "ip" and "port" keys (supports both IPv4 and IPv6)
  defp encode_peers_dict(peers) do
    Enum.map(peers, fn peer ->
      ip_string =
        case peer.ip do
          {a, b, c, d} ->
            "#{a}.#{b}.#{c}.#{d}"

          {a, b, c, d, e, f, g, h} ->
            # Format IPv6 address
            :inet.ntoa({a, b, c, d, e, f, g, h}) |> List.to_string()

          ip when is_binary(ip) ->
            ip
        end

      %{"ip" => ip_string, "port" => peer.port}
    end)
  end
end
