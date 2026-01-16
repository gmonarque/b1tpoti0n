defmodule B1tpoti0n.Persistence.Schemas.BannedIp do
  @moduledoc """
  Schema for banned IP addresses.
  Supports both individual IPs and CIDR ranges.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Bitwise

  @type t :: %__MODULE__{
          id: integer() | nil,
          ip: String.t() | nil,
          reason: String.t() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "banned_ips" do
    field :ip, :string
    field :reason, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(banned_ip, attrs) do
    banned_ip
    |> cast(attrs, [:ip, :reason, :expires_at])
    |> validate_required([:ip, :reason])
    |> validate_ip_format()
    |> unique_constraint(:ip)
  end

  defp validate_ip_format(changeset) do
    validate_change(changeset, :ip, fn :ip, ip ->
      cond do
        # CIDR notation (e.g., "192.168.1.0/24")
        String.contains?(ip, "/") ->
          case parse_cidr(ip) do
            {:ok, _} -> []
            :error -> [ip: "invalid CIDR notation"]
          end

        # Regular IP address
        true ->
          case :inet.parse_address(String.to_charlist(ip)) do
            {:ok, _} -> []
            {:error, _} -> [ip: "invalid IP address"]
          end
      end
    end)
  end

  @doc """
  Check if an IP address matches this ban entry.
  Supports both exact match and CIDR range matching.
  """
  @spec matches?(t(), String.t() | tuple()) :: boolean()
  def matches?(%__MODULE__{ip: banned_ip}, client_ip) when is_binary(client_ip) do
    case :inet.parse_address(String.to_charlist(client_ip)) do
      {:ok, client_tuple} -> matches_ip?(banned_ip, client_tuple)
      {:error, _} -> false
    end
  end

  def matches?(%__MODULE__{ip: banned_ip}, client_ip) when is_tuple(client_ip) do
    matches_ip?(banned_ip, client_ip)
  end

  defp matches_ip?(banned_ip, client_tuple) do
    if String.contains?(banned_ip, "/") do
      # CIDR match
      case parse_cidr(banned_ip) do
        {:ok, {network, prefix_len}} ->
          ip_in_cidr?(client_tuple, network, prefix_len)

        :error ->
          false
      end
    else
      # Exact match
      case :inet.parse_address(String.to_charlist(banned_ip)) do
        {:ok, banned_tuple} -> banned_tuple == client_tuple
        {:error, _} -> false
      end
    end
  end

  @doc """
  Parse a CIDR string into a network tuple and prefix length.
  """
  @spec parse_cidr(String.t()) :: {:ok, {tuple(), non_neg_integer()}} | :error
  def parse_cidr(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_str, prefix_str] ->
        with {:ok, ip_tuple} <- :inet.parse_address(String.to_charlist(ip_str)),
             {prefix_len, ""} <- Integer.parse(prefix_str),
             true <- valid_prefix_length?(ip_tuple, prefix_len) do
          {:ok, {ip_tuple, prefix_len}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp valid_prefix_length?(ip_tuple, prefix_len) when tuple_size(ip_tuple) == 4 do
    prefix_len >= 0 and prefix_len <= 32
  end

  defp valid_prefix_length?(ip_tuple, prefix_len) when tuple_size(ip_tuple) == 8 do
    prefix_len >= 0 and prefix_len <= 128
  end

  @doc """
  Check if a client IP tuple is within a CIDR range.
  """
  @spec ip_in_cidr?(tuple(), tuple(), non_neg_integer()) :: boolean()
  def ip_in_cidr?(client_ip, network_ip, prefix_len)
       when tuple_size(client_ip) == 4 and tuple_size(network_ip) == 4 do
    # IPv4: Convert to 32-bit integers and compare masked values
    client_int = ip4_to_int(client_ip)
    network_int = ip4_to_int(network_ip)
    mask = bsl(-1, 32 - prefix_len) &&& 0xFFFFFFFF
    (client_int &&& mask) == (network_int &&& mask)
  end

  def ip_in_cidr?(client_ip, network_ip, prefix_len)
       when tuple_size(client_ip) == 8 and tuple_size(network_ip) == 8 do
    # IPv6: Convert to 128-bit integers and compare masked values
    client_int = ip6_to_int(client_ip)
    network_int = ip6_to_int(network_ip)
    mask = bsl(-1, 128 - prefix_len) &&& 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    (client_int &&& mask) == (network_int &&& mask)
  end

  def ip_in_cidr?(_, _, _), do: false

  defp ip4_to_int({a, b, c, d}) do
    bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d
  end

  defp ip6_to_int({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) + bsl(b, 96) + bsl(c, 80) + bsl(d, 64) + bsl(e, 48) + bsl(f, 32) + bsl(g, 16) + h
  end
end
