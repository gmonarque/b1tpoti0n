defmodule B1tpoti0n.Network.PeerVerifier do
  @moduledoc """
  Async peer connection verification.

  Attempts TCP connections to peers to verify they can accept incoming connections.
  Results are cached in ETS to avoid repeated verification attempts.

  ## How it works

  1. On first announce, peer is queued for verification
  2. Background workers attempt TCP connect to peer's IP:port
  3. Result (connectable/not connectable) is stored with TTL
  4. Swarm workers prefer connectable peers in responses

  ## Configuration

      config :b1tpoti0n, :peer_verification,
        enabled: true,
        connect_timeout: 3000,   # 3 second timeout
        cache_ttl: 3600,         # 1 hour cache
        max_concurrent: 50,      # max concurrent verifications
        rate_limit: 100          # max verifications per minute
  """
  use GenServer
  require Logger

  @table_name :peer_verification_cache
  @verification_timeout 3_000
  @cache_ttl_seconds 3600
  @cleanup_interval_ms 60_000
  @max_concurrent 50
  @rate_limit_window_ms :timer.minutes(1)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if peer is connectable. Returns cached result if available,
  otherwise queues for verification and returns :unknown.

  Returns:
  - {:ok, true} - Peer is verified connectable
  - {:ok, false} - Peer is verified not connectable
  - :unknown - Not yet verified (queued for checking)
  """
  @spec check_connectable(tuple(), non_neg_integer()) :: {:ok, boolean()} | :unknown
  def check_connectable(ip, port) when is_tuple(ip) and is_integer(port) do
    key = {ip, port}

    case :ets.lookup(@table_name, key) do
      [{^key, connectable, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, connectable}
        else
          # Expired, queue for re-verification
          queue_verification(ip, port)
          :unknown
        end

      [] ->
        # Not in cache, queue for verification
        queue_verification(ip, port)
        :unknown
    end
  end

  @doc """
  Queue a peer for connection verification.
  """
  @spec queue_verification(tuple(), non_neg_integer()) :: :ok | {:error, :disabled}
  def queue_verification(ip, port) when is_tuple(ip) and is_integer(port) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:verify, ip, port})
    else
      {:error, :disabled}
    end
  end

  @doc """
  Get verification stats.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clear the verification cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.call(__MODULE__, :clear_cache)
  end

  @doc """
  Check if peer verification is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:b1tpoti0n, :peer_verification, [])
    Keyword.get(config, :enabled, false)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # Create ETS table for verification cache
    :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])

    schedule_cleanup()

    state = %{
      pending: :queue.new(),
      in_progress: MapSet.new(),
      verified_count: 0,
      failed_count: 0,
      rate_queue: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:verify, ip, port}, state) do
    key = {ip, port}

    # Skip if already pending or in progress
    cond do
      MapSet.member?(state.in_progress, key) ->
        {:noreply, state}

      Enum.any?(:queue.to_list(state.pending), fn {i, p} -> i == ip and p == port end) ->
        {:noreply, state}

      true ->
        {state, limited?} = enforce_rate_limit(state)

        if limited? do
          {:noreply, state}
        else
          # Add to pending queue
          new_pending = :queue.in({ip, port}, state.pending)
          state = %{state | pending: new_pending}

          # Process queue
          state = process_pending(state)
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:verification_result, {ip, port}, result}, state) do
    key = {ip, port}
    now = System.system_time(:second)
    ttl = get_cache_ttl()

    # Store result in ETS
    :ets.insert(@table_name, {key, result, now + ttl})

    # Remove from in_progress
    new_in_progress = MapSet.delete(state.in_progress, key)

    state =
      if result do
        %{state | in_progress: new_in_progress, verified_count: state.verified_count + 1}
      else
        %{state | in_progress: new_in_progress, failed_count: state.failed_count + 1}
      end

    # Process more pending verifications
    state = process_pending(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove expired entries
    now = System.system_time(:second)

    expired =
      :ets.select(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))

    if length(expired) > 0 do
      Logger.debug("Peer verifier cleaned up #{length(expired)} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    cache_size = :ets.info(@table_name, :size)

    stats = %{
      enabled: enabled?(),
      cache_size: cache_size,
      pending: :queue.len(state.pending),
      in_progress: MapSet.size(state.in_progress),
      verified_count: state.verified_count,
      failed_count: state.failed_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear_cache, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  # --- Private Helpers ---

  defp process_pending(state) do
    max_concurrent = get_max_concurrent()

    if MapSet.size(state.in_progress) < max_concurrent do
      case :queue.out(state.pending) do
        {{:value, {ip, port}}, new_pending} ->
          # Start async verification
          key = {ip, port}
          parent = self()

          Task.start(fn ->
            result = verify_peer(ip, port)
            send(parent, {:verification_result, key, result})
          end)

          new_in_progress = MapSet.put(state.in_progress, key)
          state = %{state | pending: new_pending, in_progress: new_in_progress}

          # Try to process more
          process_pending(state)

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  defp enforce_rate_limit(state) do
    case get_rate_limit() do
      :disabled ->
        {state, false}

      limit ->
        {pruned_queue, count} = prune_rate_queue(state.rate_queue)

        if count >= limit do
          {%{state | rate_queue: pruned_queue}, true}
        else
          new_queue = :queue.in(System.monotonic_time(:millisecond), pruned_queue)
          {%{state | rate_queue: new_queue}, false}
        end
    end
  end

  defp prune_rate_queue(queue) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @rate_limit_window_ms
    prune_rate_queue(queue, window_start)
  end

  defp prune_rate_queue(queue, window_start) do
    case :queue.out(queue) do
      {{:value, timestamp}, rest} when timestamp < window_start ->
        prune_rate_queue(rest, window_start)

      {{:value, _timestamp}, _rest} ->
        {queue, :queue.len(queue)}

      {:empty, _} ->
        {queue, 0}
    end
  end

  defp get_rate_limit do
    config = Application.get_env(:b1tpoti0n, :peer_verification, [])
    case Keyword.get(config, :rate_limit, 100) do
      nil -> :disabled
      0 -> :disabled
      :infinity -> :disabled
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> :disabled
    end
  end

  defp verify_peer(ip, port) do
    # Block verification of private/reserved IP ranges to prevent SSRF
    if is_private_ip?(ip) do
      Logger.debug("Skipping verification of private IP: #{:inet.ntoa(ip)}")
      false
    else
      timeout = get_connect_timeout()

      case :gen_tcp.connect(ip, port, [:binary, active: false], timeout) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _reason} ->
          false
      end
    end
  end

  # Check if IP is in private/reserved ranges (RFC 1918, loopback, link-local, etc.)
  # Loopback
  defp is_private_ip?({127, _, _, _}), do: true
  # Class A private
  defp is_private_ip?({10, _, _, _}), do: true
  # Class B private
  defp is_private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # Class C private
  defp is_private_ip?({192, 168, _, _}), do: true
  # Link-local
  defp is_private_ip?({169, 254, _, _}), do: true
  # Current network
  defp is_private_ip?({0, _, _, _}), do: true
  # Broadcast
  defp is_private_ip?({255, 255, 255, 255}), do: true
  # IPv6 private ranges
  # ::1 loopback
  defp is_private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # Link-local
  defp is_private_ip?({0xFE80, _, _, _, _, _, _, _}), do: true
  # Unique local (fc00::/7)
  defp is_private_ip?({0xFC00, _, _, _, _, _, _, _}), do: true
  # Unique local (fc00::/7)
  defp is_private_ip?({0xFD00, _, _, _, _, _, _, _}), do: true
  defp is_private_ip?(_), do: false

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp get_connect_timeout do
    config = Application.get_env(:b1tpoti0n, :peer_verification, [])
    Keyword.get(config, :connect_timeout, @verification_timeout)
  end

  defp get_cache_ttl do
    config = Application.get_env(:b1tpoti0n, :peer_verification, [])
    Keyword.get(config, :cache_ttl, @cache_ttl_seconds)
  end

  defp get_max_concurrent do
    config = Application.get_env(:b1tpoti0n, :peer_verification, [])
    Keyword.get(config, :max_concurrent, @max_concurrent)
  end
end
