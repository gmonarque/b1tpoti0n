defmodule B1tpoti0n.Store.Manager do
  @moduledoc """
  GenServer that owns ETS tables for passkeys, whitelist, and banned IPs.
  Uses protected tables with read_concurrency for optimal read performance.

  Tables:
  - :b1tpoti0n_passkeys - Maps passkey -> user_id
  - :b1tpoti0n_whitelist - Maps client_prefix -> name
  - :b1tpoti0n_banned_ips - Stores banned IP records for fast lookup
  """
  use GenServer
  require Logger

  alias B1tpoti0n.Persistence.Schemas.BannedIp

  @passkey_table :b1tpoti0n_passkeys
  @whitelist_table :b1tpoti0n_whitelist
  @banned_ips_table :b1tpoti0n_banned_ips

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a user ID by passkey. Returns {:ok, user_id} or :error.
  Direct ETS access for performance.
  """
  @spec lookup_passkey(String.t()) :: {:ok, integer()} | :error
  def lookup_passkey(passkey) do
    case :ets.lookup(@passkey_table, passkey) do
      [{^passkey, user_id}] -> {:ok, user_id}
      [] -> :error
    end
  end

  @doc """
  Check if a peer_id's client prefix is whitelisted.
  Returns true if the first 3 characters match a whitelisted prefix.
  """
  @spec valid_client?(binary()) :: boolean()
  def valid_client?(peer_id) when byte_size(peer_id) >= 3 do
    prefix = binary_part(peer_id, 0, 3)
    :ets.member(@whitelist_table, prefix)
  end

  def valid_client?(_), do: false

  @doc """
  Check if an IP address is banned.
  Checks both exact matches and CIDR ranges.
  Returns {:banned, reason} if banned, :ok otherwise.
  """
  @spec check_banned(String.t() | tuple()) :: :ok | {:banned, String.t()}
  def check_banned(ip) do
    now = DateTime.utc_now()

    case :ets.tab2list(@banned_ips_table) do
      [] ->
        :ok

      bans ->
        matching_ban =
          Enum.find(bans, fn {_id, banned_ip_struct} ->
            not_expired =
              is_nil(banned_ip_struct.expires_at) or
                DateTime.compare(banned_ip_struct.expires_at, now) == :gt

            not_expired and BannedIp.matches?(banned_ip_struct, ip)
          end)

        case matching_ban do
          nil -> :ok
          {_id, ban} -> {:banned, ban.reason}
        end
    end
  end

  @doc """
  Reload passkeys from the database.
  """
  @spec reload_passkeys() :: :ok
  def reload_passkeys do
    GenServer.call(__MODULE__, :reload_passkeys)
  end

  @doc """
  Reload whitelist from the database.
  """
  @spec reload_whitelist() :: :ok
  def reload_whitelist do
    GenServer.call(__MODULE__, :reload_whitelist)
  end

  @doc """
  Reload banned IPs from the database.
  """
  @spec reload_banned_ips() :: :ok
  def reload_banned_ips do
    GenServer.call(__MODULE__, :reload_banned_ips)
  end

  @doc """
  Get stats about the ETS tables.
  """
  @spec stats() :: map()
  def stats do
    %{
      passkeys: :ets.info(@passkey_table, :size),
      whitelist: :ets.info(@whitelist_table, :size),
      banned_ips: :ets.info(@banned_ips_table, :size)
    }
  end

  @impl true
  def init(_opts) do
    :ets.new(@passkey_table, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    :ets.new(@whitelist_table, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    :ets.new(@banned_ips_table, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    Logger.info("Store.Manager started, ETS tables created")

    {:ok, %{}, {:continue, :hydrate}}
  end

  @impl true
  def handle_continue(:hydrate, state) do
    hydrate_passkeys()
    hydrate_whitelist()
    hydrate_banned_ips()
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_passkeys, _from, state) do
    hydrate_passkeys()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reload_whitelist, _from, state) do
    hydrate_whitelist()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reload_banned_ips, _from, state) do
    hydrate_banned_ips()
    {:reply, :ok, state}
  end

  defp hydrate_passkeys do
    alias B1tpoti0n.Persistence.Repo
    alias B1tpoti0n.Persistence.Schemas.User
    import Ecto.Query

    try do
      users = Repo.all(from(u in User, select: {u.passkey, u.id}))
      :ets.delete_all_objects(@passkey_table)
      :ets.insert(@passkey_table, users)
      Logger.info("Loaded #{length(users)} passkeys into ETS")
    rescue
      e ->
        Logger.warning("Failed to hydrate passkeys: #{inspect(e)}")
    end
  end

  defp hydrate_whitelist do
    alias B1tpoti0n.Persistence.Repo
    alias B1tpoti0n.Persistence.Schemas.Whitelist
    import Ecto.Query

    try do
      clients = Repo.all(from(w in Whitelist, select: {w.client_prefix, w.name}))
      :ets.delete_all_objects(@whitelist_table)
      :ets.insert(@whitelist_table, clients)
      Logger.info("Loaded #{length(clients)} whitelisted clients into ETS")
    rescue
      e ->
        Logger.warning("Failed to hydrate whitelist: #{inspect(e)}")
    end
  end

  defp hydrate_banned_ips do
    alias B1tpoti0n.Persistence.Repo

    try do
      bans = Repo.all(BannedIp)
      entries = Enum.map(bans, fn ban -> {ban.id, ban} end)
      :ets.delete_all_objects(@banned_ips_table)
      :ets.insert(@banned_ips_table, entries)
      Logger.info("Loaded #{length(entries)} banned IPs into ETS")
    rescue
      e ->
        Logger.warning("Failed to hydrate banned IPs: #{inspect(e)}")
    end
  end
end
