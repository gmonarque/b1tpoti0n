defmodule B1tpoti0n.Swarm.Worker do
  @moduledoc """
  GenServer managing peers for a single torrent (info_hash).
  Maintains peer list with periodic cleanup of inactive peers.

  Peer storage is configurable via:

      config :b1tpoti0n,
        peer_storage: :memory  # or :redis

  State structure:
  - info_hash: 20-byte binary
  - torrent_id: database ID
  - completed: Total completed downloads (delta for DB sync)
  """
  use GenServer
  require Logger

  alias B1tpoti0n.Network.PeerVerifier
  alias B1tpoti0n.Swarm.PeerStorage

  # Peer timeout: 1 hour of inactivity
  @peer_timeout_seconds 3600

  # Cleanup interval: every 5 minutes
  @cleanup_interval_ms 300_000

  # Idle timeout: terminate worker after 1 hour with no peers
  @idle_timeout_ms 3_600_000

  # DB stats sync interval: every 30 seconds
  @db_sync_interval_ms 30_000

  defstruct [:info_hash, :torrent_id, :mode, completed: 0, completed_delta: 0]

  # --- Client API ---

  def start_link({info_hash, torrent_id}) do
    GenServer.start_link(__MODULE__, {info_hash, torrent_id, :local}, name: via_tuple(info_hash))
  end

  def start_link({info_hash, torrent_id, :distributed}) do
    GenServer.start_link(__MODULE__, {info_hash, torrent_id, :distributed},
      name: via_tuple_distributed(info_hash)
    )
  end

  @doc """
  Get the via tuple for local Registry lookup.
  """
  def via_tuple(info_hash) do
    {:via, Registry, {B1tpoti0n.Swarm.Registry, info_hash}}
  end

  @doc """
  Get the via tuple for distributed Horde Registry lookup.
  """
  def via_tuple_distributed(info_hash) do
    {:via, Horde.Registry, {B1tpoti0n.Swarm.DistributedRegistry, info_hash}}
  end

  @doc """
  Process an announce from a peer.
  Returns {seeders, leechers, peer_list, stats_delta, announce_key} on success,
  or {:error, reason} if the announce key validation fails.

  stats_delta is a map with :uploaded and :downloaded deltas for this user.
  announce_key is a unique key for this peer (for key rotation/anti-spoofing).
  """
  @spec announce(pid() | tuple(), map(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), list(), map(), binary() | nil}
          | {:error, :key_required | :invalid_key}
  def announce(pid_or_name, peer_data, num_want) do
    GenServer.call(pid_or_name, {:announce, peer_data, num_want})
  end

  @doc """
  Generate a unique announce key for peer anti-spoofing.
  """
  @spec generate_announce_key() :: binary()
  def generate_announce_key do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc """
  Get torrent stats for scrape.
  Returns {seeders, completed, leechers}.
  """
  @spec get_stats(pid() | tuple()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def get_stats(pid_or_name) do
    GenServer.call(pid_or_name, :get_stats)
  end

  @doc """
  Get a list of peers without processing an announce.
  """
  @spec get_peers(pid() | tuple(), non_neg_integer()) :: list()
  def get_peers(pid_or_name, num_want) do
    GenServer.call(pid_or_name, {:get_peers, num_want})
  end

  # --- Server Callbacks ---

  @impl true
  def init({info_hash, torrent_id, mode}) do
    schedule_cleanup()
    schedule_idle_check()
    schedule_db_sync()

    state = %__MODULE__{
      info_hash: info_hash,
      torrent_id: torrent_id,
      mode: mode,
      completed: 0,
      completed_delta: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:announce, peer_data, num_want}, _from, state) do
    require Logger
    # SECURITY: Use debug level to avoid exposing user activity patterns in production logs
    Logger.debug(
      "Announce: event=#{peer_data.event} left=#{peer_data.left} up=#{peer_data.uploaded} down=#{peer_data.downloaded}"
    )

    key = {peer_data.ip, peer_data.port}
    now = System.system_time(:second)

    # Get previous stats for delta calculation
    old_peer = PeerStorage.get_peer(state.info_hash, key)
    old_uploaded = if old_peer, do: Map.get(old_peer, :uploaded, 0), else: 0
    old_downloaded = if old_peer, do: Map.get(old_peer, :downloaded, 0), else: 0

    current_uploaded = Map.get(peer_data, :uploaded, 0)
    current_downloaded = Map.get(peer_data, :downloaded, 0)

    # Calculate deltas (handle client restart where current < old)
    # SECURITY: Cap deltas at 100GB per announce to prevent stats inflation attacks
    # Normal announces occur every ~30 minutes, so 100GB is extremely generous
    # 100 GB
    max_delta_per_announce = 100 * 1024 * 1024 * 1024

    upload_delta =
      (current_uploaded - old_uploaded)
      |> max(0)
      |> min(max_delta_per_announce)

    download_delta =
      (current_downloaded - old_downloaded)
      |> max(0)
      |> min(max_delta_per_announce)

    stats_delta = %{
      user_id: peer_data.user_id,
      uploaded: upload_delta,
      downloaded: download_delta
    }

    # Handle key rotation (anti-spoofing)
    # Can be disabled via config for client compatibility
    enforce_announce_key = Application.get_env(:b1tpoti0n, :enforce_announce_key, true)
    request_key = Map.get(peer_data, :key)
    existing_key = if old_peer, do: Map.get(old_peer, :announce_key), else: nil

    # Validate key if peer already exists and has a key
    key_validation =
      cond do
        # Feature disabled - skip validation
        not enforce_announce_key ->
          :ok

        # New peer - no validation needed
        is_nil(existing_key) ->
          :ok

        # Existing peer with key - validate
        is_nil(request_key) ->
          # No key provided but one is required
          {:error, :key_required}

        request_key != existing_key ->
          # Wrong key
          {:error, :invalid_key}

        true ->
          :ok
      end

    case key_validation do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        # Generate or use existing key
        announce_key = existing_key || generate_announce_key()

        # Handle stopped event (remove peer)
        state =
          if peer_data.event == :stopped do
            PeerStorage.delete_peer(state.info_hash, key)
            state
          else
            # Update or add peer
            is_seeder = peer_data.left == 0

            # Check/queue peer verification
            connectable =
              case PeerVerifier.check_connectable(peer_data.ip, peer_data.port) do
                {:ok, result} -> result
                :unknown -> nil
              end

            peer_entry = %{
              ip: peer_data.ip,
              port: peer_data.port,
              user_id: peer_data.user_id,
              peer_id: Map.get(peer_data, :peer_id),
              is_seeder: is_seeder,
              updated_at: now,
              uploaded: current_uploaded,
              downloaded: current_downloaded,
              announce_key: announce_key,
              connectable: connectable
            }

            PeerStorage.put_peer(state.info_hash, key, peer_entry)

            # Track completed event (increment both total and delta for DB sync)
            if peer_data.event == :completed do
              %{
                state
                | completed: state.completed + 1,
                  completed_delta: state.completed_delta + 1
              }
            else
              state
            end
          end

        # Get current counts from storage
        {seeders, leechers} = PeerStorage.get_counts(state.info_hash)

        # Select random peers, preferring seeders for leechers
        requesting_is_leecher = Map.get(peer_data, :left, 1) > 0
        all_peers = PeerStorage.get_all_peers(state.info_hash)
        peers = select_peers(all_peers, key, num_want, requesting_is_leecher)

        {:reply, {seeders, leechers, peers, stats_delta, announce_key}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {seeders, leechers} = PeerStorage.get_counts(state.info_hash)
    {:reply, {seeders, state.completed, leechers}, state}
  end

  @impl true
  def handle_call(:peer_count, _from, state) do
    count = PeerStorage.count_peers(state.info_hash)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_call({:get_peers, num_want}, _from, state) do
    all_peers = PeerStorage.get_all_peers(state.info_hash)
    peers = select_peers(all_peers, nil, num_want, true)
    {:reply, peers, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    cutoff = now - @peer_timeout_seconds

    # Remove expired peers from storage
    expired_count = PeerStorage.cleanup_expired(state.info_hash, cutoff)

    if expired_count > 0 do
      Logger.info(
        "Cleaned up #{expired_count} expired peers for torrent #{Base.encode16(state.info_hash, case: :lower)}"
      )
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    peer_count = PeerStorage.count_peers(state.info_hash)

    if peer_count == 0 do
      # Sync to DB before terminating
      sync_to_db(state)
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:db_sync, state) do
    sync_to_db(state)
    schedule_db_sync()
    # Reset the completed delta after syncing
    {:noreply, %{state | completed_delta: 0}}
  end

  # --- Private Helpers ---

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout_ms)
  end

  defp schedule_db_sync do
    Process.send_after(self(), :db_sync, @db_sync_interval_ms)
  end

  defp sync_to_db(%{torrent_id: nil}), do: :ok

  defp sync_to_db(state) do
    {seeders, leechers} = PeerStorage.get_counts(state.info_hash)

    B1tpoti0n.Torrents.update_stats(
      state.torrent_id,
      seeders,
      leechers,
      state.completed_delta
    )
  end

  defp select_peers(peers, exclude_key, num_want, prefer_seeders) do
    peer_list =
      peers
      |> Map.values()
      |> Enum.reject(fn p ->
        exclude_key != nil and {p.ip, p.port} == exclude_key
      end)

    # Sort peers by priority:
    # 1. Connectable peers first (if known)
    # 2. If requesting peer is a leecher, prefer seeders
    # 3. Random order within same priority
    sorted =
      peer_list
      |> Enum.map(fn p -> {p, :rand.uniform()} end)
      |> Enum.sort_by(fn {p, rand} ->
        connectable_score =
          case Map.get(p, :connectable) do
            true -> 0
            nil -> 1
            false -> 2
          end

        seeder_score =
          if prefer_seeders do
            if p.is_seeder, do: 0, else: 1
          else
            0
          end

        # Primary: connectable, Secondary: seeder, Tertiary: random
        {connectable_score, seeder_score, rand}
      end)
      |> Enum.map(fn {p, _} -> p end)

    Enum.take(sorted, min(num_want, 50))
  end
end
