defmodule B1tpoti0n.Admin do
  @moduledoc """
  Administrative functions for managing users, torrents, and tracker state.

  ## Usage in IEx

      iex> alias B1tpoti0n.Admin
      iex> {:ok, user} = Admin.create_user()
      iex> user.passkey
      "a1b2c3d4e5f6..."

  """
  import Ecto.Query

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.{User, Torrent, Peer, Whitelist, BannedIp}
  alias B1tpoti0n.Store.Manager

  # ============================================================================
  # User Management
  # ============================================================================

  @doc """
  Create a new user with a randomly generated passkey.

  ## Examples

      iex> {:ok, user} = Admin.create_user()
      iex> String.length(user.passkey)
      32
  """
  @spec create_user() :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user do
    create_user(User.generate_passkey())
  end

  @doc """
  Create a new user with a specific passkey.

  ## Examples

      iex> {:ok, user} = Admin.create_user("my32characterpasskey0000000000001")
  """
  @spec create_user(String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def create_user(passkey) when is_binary(passkey) and byte_size(passkey) == 32 do
    result =
      %User{}
      |> User.changeset(%{passkey: passkey})
      |> Repo.insert()

    case result do
      {:ok, user} ->
        Manager.reload_passkeys()
        {:ok, user}

      error ->
        error
    end
  end

  def create_user(passkey) when is_binary(passkey) do
    {:error, "Passkey must be exactly 32 characters, got #{byte_size(passkey)}"}
  end

  @doc """
  List all users with their stats.

  ## Options
  - `:limit` - Maximum number of users to return (default: 100)
  - `:order_by` - Field to order by: `:id`, `:uploaded`, `:downloaded` (default: `:id`)
  """
  @spec list_users(keyword()) :: [User.t()]
  def list_users(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    order_by = Keyword.get(opts, :order_by, :id)

    User
    |> order_by([u], field(u, ^order_by))
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get a user by ID.
  """
  @spec get_user(integer()) :: User.t() | nil
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Get a user by passkey.
  """
  @spec get_user_by_passkey(String.t()) :: User.t() | nil
  def get_user_by_passkey(passkey) do
    Repo.get_by(User, passkey: passkey)
  end

  @doc """
  Get user stats by passkey. Returns a formatted map.
  """
  @spec get_user_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_user_stats(passkey) do
    case get_user_by_passkey(passkey) do
      nil ->
        {:error, :not_found}

      user ->
        {:ok,
         %{
           id: user.id,
           passkey: user.passkey,
           uploaded: format_bytes(user.uploaded),
           downloaded: format_bytes(user.downloaded),
           ratio: calculate_ratio(user.uploaded, user.downloaded),
           raw_uploaded: user.uploaded,
           raw_downloaded: user.downloaded
         }}
    end
  end

  @doc """
  Delete a user by ID. Also removes all their peer records.
  """
  @spec delete_user(integer()) :: {:ok, User.t()} | {:error, :not_found}
  def delete_user(id) do
    case Repo.get(User, id) do
      nil ->
        {:error, :not_found}

      user ->
        result = Repo.delete(user)
        Manager.reload_passkeys()
        result
    end
  end

  @doc """
  Reset a user's passkey to a new random value.
  """
  @spec reset_passkey(integer()) :: {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reset_passkey(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        result =
          user
          |> User.changeset(%{passkey: User.generate_passkey()})
          |> Repo.update()

        case result do
          {:ok, _} -> Manager.reload_passkeys()
          _ -> :ok
        end

        result
    end
  end

  @doc """
  Update user's upload/download stats.

  ## Options
  - `:operation` - :set (default), :add, or :subtract

  ## Examples

      iex> Admin.update_user_stats(1, uploaded: 1_000_000_000)
      {:ok, %User{}}

      iex> Admin.update_user_stats(1, [uploaded: 500_000_000], operation: :add)
      {:ok, %User{}}
  """
  @spec update_user_stats(integer(), keyword(), keyword()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_user_stats(user_id, stats, opts \\ []) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        operation = Keyword.get(opts, :operation, :set)

        changes =
          case operation do
            :set ->
              %{
                uploaded: Keyword.get(stats, :uploaded, user.uploaded),
                downloaded: Keyword.get(stats, :downloaded, user.downloaded)
              }

            :add ->
              %{
                uploaded: user.uploaded + Keyword.get(stats, :uploaded, 0),
                downloaded: user.downloaded + Keyword.get(stats, :downloaded, 0)
              }

            :subtract ->
              %{
                uploaded: max(0, user.uploaded - Keyword.get(stats, :uploaded, 0)),
                downloaded: max(0, user.downloaded - Keyword.get(stats, :downloaded, 0))
              }
          end

        user
        |> User.changeset(changes)
        |> Repo.update()
    end
  end

  @doc """
  Update user's can_leech status.
  """
  @spec update_user_can_leech(integer(), boolean()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_user_can_leech(user_id, can_leech) when is_boolean(can_leech) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> User.changeset(%{can_leech: can_leech})
        |> Repo.update()
    end
  end

  @doc """
  Clear all HnR warnings for a user and re-enable leeching.
  """
  @spec clear_user_warnings(integer()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def clear_user_warnings(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> User.changeset(%{hnr_warnings: 0, can_leech: true})
        |> Repo.update()
    end
  end

  @doc """
  Search users by passkey (partial or exact match).
  """
  @spec search_users(String.t()) :: [User.t()]
  def search_users(query) when is_binary(query) do
    pattern = "%#{query}%"

    from(u in User, where: like(u.passkey, ^pattern))
    |> Repo.all()
  end

  @doc """
  Get a user's currently active peer connections across all swarms.

  Returns a list of maps containing info_hash and peer data for each
  torrent the user is currently seeding or leeching.

  ## Examples

      iex> Admin.get_user_active_peers(123)
      [%{info_hash: "abc123...", is_seeder: true, uploaded: 1000, ...}, ...]
  """
  @spec get_user_active_peers(integer()) :: [map()]
  def get_user_active_peers(user_id) when is_integer(user_id) do
    alias B1tpoti0n.Swarm
    alias B1tpoti0n.Swarm.PeerStorage

    Swarm.list_workers()
    |> Enum.flat_map(fn {info_hash, _pid} ->
      peers = PeerStorage.get_all_peers(info_hash)

      peers
      |> Enum.filter(fn {_key, peer} -> peer[:user_id] == user_id end)
      |> Enum.map(fn {{ip, port}, peer} ->
        %{
          info_hash: Base.encode16(info_hash, case: :lower),
          ip: ip,
          port: port,
          is_seeder: peer[:is_seeder] || false,
          uploaded: peer[:uploaded] || 0,
          downloaded: peer[:downloaded] || 0,
          updated_at: peer[:updated_at]
        }
      end)
    end)
  end

  # ============================================================================
  # Whitelist Management
  # ============================================================================

  @doc """
  Add a client to the whitelist.

  ## Examples

      iex> Admin.add_to_whitelist("-TR", "Transmission")
      {:ok, %Whitelist{}}
  """
  @spec add_to_whitelist(String.t(), String.t()) ::
          {:ok, Whitelist.t()} | {:error, Ecto.Changeset.t()}
  def add_to_whitelist(prefix, name) do
    result =
      %Whitelist{}
      |> Whitelist.changeset(%{client_prefix: prefix, name: name})
      |> Repo.insert()

    case result do
      {:ok, _} -> Manager.reload_whitelist()
      _ -> :ok
    end

    result
  end

  @doc """
  Remove a client from the whitelist.
  """
  @spec remove_from_whitelist(String.t()) :: {:ok, Whitelist.t()} | {:error, :not_found}
  def remove_from_whitelist(prefix) do
    case Repo.get_by(Whitelist, client_prefix: prefix) do
      nil ->
        {:error, :not_found}

      entry ->
        result = Repo.delete(entry)
        Manager.reload_whitelist()
        result
    end
  end

  @doc """
  List all whitelisted clients.
  """
  @spec list_whitelist() :: [Whitelist.t()]
  def list_whitelist do
    Repo.all(Whitelist)
  end

  # ============================================================================
  # IP Ban Management
  # ============================================================================

  @doc """
  Ban an IP address or CIDR range.

  ## Options
  - `:duration` - Ban duration in seconds (nil = permanent)

  ## Examples

      iex> Admin.ban_ip("192.168.1.100", "Abuse")
      {:ok, %BannedIp{}}

      iex> Admin.ban_ip("10.0.0.0/8", "Internal network", duration: 3600)
      {:ok, %BannedIp{}}
  """
  @spec ban_ip(String.t(), String.t(), keyword()) ::
          {:ok, BannedIp.t()} | {:error, Ecto.Changeset.t()}
  def ban_ip(ip, reason, opts \\ []) do
    duration = Keyword.get(opts, :duration)

    expires_at =
      if duration do
        DateTime.utc_now() |> DateTime.add(duration, :second)
      else
        nil
      end

    result =
      %BannedIp{}
      |> BannedIp.changeset(%{ip: ip, reason: reason, expires_at: expires_at})
      |> Repo.insert()

    case result do
      {:ok, _} -> Manager.reload_banned_ips()
      _ -> :ok
    end

    result
  end

  @doc """
  Unban an IP address.
  """
  @spec unban_ip(String.t()) :: {:ok, BannedIp.t()} | {:error, :not_found}
  def unban_ip(ip) do
    case Repo.get_by(BannedIp, ip: ip) do
      nil ->
        {:error, :not_found}

      entry ->
        result = Repo.delete(entry)
        Manager.reload_banned_ips()
        result
    end
  end

  @doc """
  List all banned IPs.
  """
  @spec list_bans() :: [BannedIp.t()]
  def list_bans do
    Repo.all(BannedIp)
  end

  @doc """
  List only active (non-expired) bans.
  """
  @spec list_active_bans() :: [BannedIp.t()]
  def list_active_bans do
    now = DateTime.utc_now()

    from(b in BannedIp,
      where: is_nil(b.expires_at) or b.expires_at > ^now
    )
    |> Repo.all()
  end

  @doc """
  Get a ban by IP.
  """
  @spec get_ban(String.t()) :: BannedIp.t() | nil
  def get_ban(ip) do
    Repo.get_by(BannedIp, ip: ip)
  end

  @doc """
  Update an existing ban.

  ## Options
  - `:reason` - New reason for the ban
  - `:duration` - New duration in seconds from now (nil = permanent)
  """
  @spec update_ban(String.t(), keyword()) ::
          {:ok, BannedIp.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_ban(ip, opts) do
    case Repo.get_by(BannedIp, ip: ip) do
      nil ->
        {:error, :not_found}

      ban ->
        changes = %{}

        changes =
          if Keyword.has_key?(opts, :reason) do
            Map.put(changes, :reason, Keyword.get(opts, :reason))
          else
            changes
          end

        changes =
          if Keyword.has_key?(opts, :duration) do
            duration = Keyword.get(opts, :duration)

            expires_at =
              if duration do
                DateTime.utc_now() |> DateTime.add(duration, :second)
              else
                nil
              end

            Map.put(changes, :expires_at, expires_at)
          else
            changes
          end

        result =
          ban
          |> BannedIp.changeset(changes)
          |> Repo.update()

        case result do
          {:ok, _} -> Manager.reload_banned_ips()
          _ -> :ok
        end

        result
    end
  end

  @doc """
  Clean up expired bans from the database.
  """
  @spec cleanup_expired_bans() :: {integer(), nil}
  def cleanup_expired_bans do
    now = DateTime.utc_now()

    {count, _} =
      from(b in BannedIp, where: not is_nil(b.expires_at) and b.expires_at < ^now)
      |> Repo.delete_all()

    if count > 0 do
      Manager.reload_banned_ips()
    end

    {count, nil}
  end

  # ============================================================================
  # Torrent Management
  # ============================================================================

  @doc """
  Register a torrent by hex-encoded info_hash.
  Required when `enforce_torrent_whitelist: true` is set.

  ## Examples

      iex> Admin.register_torrent("0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33")
      {:ok, %Torrent{}}
  """
  @spec register_torrent(String.t()) :: {:ok, Torrent.t()} | {:error, term()}
  def register_torrent(info_hash_hex) when byte_size(info_hash_hex) == 40 do
    B1tpoti0n.Torrents.register_hex(info_hash_hex)
  end

  def register_torrent(info_hash) when byte_size(info_hash) == 20 do
    B1tpoti0n.Torrents.register(info_hash)
  end

  @doc """
  Delete a torrent by ID.
  """
  @spec delete_torrent(integer()) :: {:ok, Torrent.t()} | {:error, :not_found}
  def delete_torrent(id) do
    case Repo.get(Torrent, id) do
      nil -> {:error, :not_found}
      torrent -> Repo.delete(torrent)
    end
  end

  @doc """
  List all known torrents with stats.
  """
  @spec list_torrents(keyword()) :: [Torrent.t()]
  def list_torrents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Torrent
    |> order_by([t], desc: t.seeders)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get torrent by ID.
  """
  @spec get_torrent_by_id(integer()) :: Torrent.t() | nil
  def get_torrent_by_id(id) do
    Repo.get(Torrent, id)
  end

  @doc """
  Get torrent by info_hash (binary or hex string).
  """
  @spec get_torrent(binary() | String.t()) :: Torrent.t() | nil
  def get_torrent(info_hash) when byte_size(info_hash) == 20 do
    Repo.get_by(Torrent, info_hash: info_hash)
  end

  def get_torrent(info_hash_hex) when byte_size(info_hash_hex) == 40 do
    case Base.decode16(info_hash_hex, case: :mixed) do
      {:ok, binary} -> get_torrent(binary)
      :error -> nil
    end
  end

  # ============================================================================
  # Tracker Stats
  # ============================================================================

  @doc """
  Get overall tracker statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      users: Repo.aggregate(User, :count),
      torrents: Repo.aggregate(Torrent, :count),
      peers: Repo.aggregate(Peer, :count),
      whitelisted_clients: Repo.aggregate(Whitelist, :count),
      active_swarms: B1tpoti0n.Swarm.count_workers(),
      ets: Manager.stats(),
      total_uploaded: Repo.aggregate(User, :sum, :uploaded) || 0,
      total_downloaded: Repo.aggregate(User, :sum, :downloaded) || 0,
      cluster: B1tpoti0n.Cluster.status()
    }
  end

  @doc """
  Print a formatted stats summary.
  """
  @spec print_stats() :: :ok
  def print_stats do
    s = stats()

    IO.puts("""

    ╔══════════════════════════════════════════════════════════╗
    ║                   Tracker Statistics                     ║
    ╠══════════════════════════════════════════════════════════╣
    ║  Users:              #{String.pad_leading(to_string(s.users), 10)}                       ║
    ║  Torrents (DB):      #{String.pad_leading(to_string(s.torrents), 10)}                       ║
    ║  Active Swarms:      #{String.pad_leading(to_string(s.active_swarms), 10)}                       ║
    ║  Peers (DB):         #{String.pad_leading(to_string(s.peers), 10)}                       ║
    ║  Whitelisted:        #{String.pad_leading(to_string(s.whitelisted_clients), 10)}                       ║
    ╠══════════════════════════════════════════════════════════╣
    ║  Total Uploaded:     #{String.pad_leading(format_bytes(s.total_uploaded), 10)}                       ║
    ║  Total Downloaded:   #{String.pad_leading(format_bytes(s.total_downloaded), 10)}                       ║
    ╠══════════════════════════════════════════════════════════╣
    ║  ETS Passkeys:       #{String.pad_leading(to_string(s.ets.passkeys), 10)}                       ║
    ║  ETS Whitelist:      #{String.pad_leading(to_string(s.ets.whitelist), 10)}                       ║
    ╚══════════════════════════════════════════════════════════╝
    """)

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @kb 1024
  @mb @kb * 1024
  @gb @mb * 1024

  defp format_bytes(bytes) when bytes < @kb, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < @mb, do: "#{Float.round(bytes / @kb, 1)} KB"
  defp format_bytes(bytes) when bytes < @gb, do: "#{Float.round(bytes / @mb, 2)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / @gb, 2)} GB"

  defp calculate_ratio(_uploaded, 0), do: "∞"
  defp calculate_ratio(uploaded, downloaded), do: Float.round(uploaded / downloaded, 2)
end
