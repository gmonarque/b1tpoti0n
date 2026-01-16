defmodule B1tpoti0n.Network.RateLimiter do
  @moduledoc """
  ETS-based token bucket rate limiter.

  Provides rate limiting per IP address with configurable limits.
  Uses a sliding window approach for accurate rate tracking.

  ## Configuration

      config :b1tpoti0n,
        rate_limits: [
          announce: {30, :per_minute},
          scrape: {10, :per_minute},
          admin_api: {100, :per_minute}
        ],
        rate_limit_whitelist: ["127.0.0.1", "::1"]
  """
  use GenServer
  require Logger

  @table :b1tpoti0n_rate_limits
  @cleanup_interval :timer.minutes(1)
  @window_ms :timer.minutes(1)

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed for the given IP and limit type.
  Returns :ok if allowed, {:error, :rate_limited, retry_after_ms} if exceeded.
  """
  @spec check(String.t(), atom()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(ip, limit_type) do
    if rate_limiting_enabled?() do
      do_check(ip, limit_type)
    else
      :ok
    end
  end

  defp do_check(ip, limit_type) do
    if whitelisted?(ip) do
      :ok
    else
      {max_requests, _period} = get_limit(limit_type)
      now = System.monotonic_time(:millisecond)
      key = {ip, limit_type}

      case :ets.lookup(@table, key) do
        [] ->
          # First request, allow it
          :ets.insert(@table, {key, [{now, 1}]})
          :ok

        [{^key, timestamps}] ->
          # Filter to only timestamps within the window
          window_start = now - @window_ms
          valid_timestamps = Enum.filter(timestamps, fn {ts, _} -> ts > window_start end)
          request_count = Enum.reduce(valid_timestamps, 0, fn {_, c}, acc -> acc + c end)

          if request_count < max_requests do
            # Allow request, add timestamp
            new_timestamps = [{now, 1} | valid_timestamps]
            :ets.insert(@table, {key, new_timestamps})
            :ok
          else
            # Rate limited - calculate retry time
            oldest_in_window =
              valid_timestamps
              |> Enum.map(fn {ts, _} -> ts end)
              |> Enum.min(fn -> now end)

            retry_after = oldest_in_window + @window_ms - now
            {:error, :rate_limited, max(0, retry_after)}
          end
      end
    end
  end

  @doc """
  Reset rate limit state for an IP address (all limit types).
  """
  @spec reset(String.t()) :: :ok
  def reset(ip) do
    :ets.match_delete(@table, {{ip, :_}, :_})
    :ok
  end

  @doc """
  Reset rate limit state for a specific IP and limit type.
  """
  @spec reset(String.t(), atom()) :: :ok
  def reset(ip, limit_type) do
    :ets.delete(@table, {ip, limit_type})
    :ok
  end

  @doc """
  Get current rate limit state for an IP.
  """
  @spec get_state(String.t()) :: map()
  def get_state(ip) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    [:announce, :scrape, :admin_api]
    |> Enum.map(fn limit_type ->
      key = {ip, limit_type}
      {max_requests, _} = get_limit(limit_type)

      count =
        case :ets.lookup(@table, key) do
          [] ->
            0

          [{^key, timestamps}] ->
            timestamps
            |> Enum.filter(fn {ts, _} -> ts > window_start end)
            |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)
        end

      {limit_type, %{count: count, limit: max_requests, remaining: max(0, max_requests - count)}}
    end)
    |> Map.new()
  end

  @doc """
  Get overall rate limiter statistics.
  """
  @spec stats() :: map()
  def stats do
    info = :ets.info(@table)

    %{
      entries: Keyword.get(info, :size, 0),
      memory_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    }
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    schedule_cleanup()
    Logger.debug("RateLimiter started with table #{inspect(table)}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    # Get all entries and filter out expired timestamps
    :ets.tab2list(@table)
    |> Enum.each(fn {key, timestamps} ->
      valid = Enum.filter(timestamps, fn {ts, _} -> ts > window_start end)

      if Enum.empty?(valid) do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, valid})
      end
    end)
  end

  defp get_limit(limit_type) do
    limits = Application.get_env(:b1tpoti0n, :rate_limits, default_limits())
    Keyword.get(limits, limit_type, {1000, :per_minute})
  end

  defp default_limits do
    [
      announce: {30, :per_minute},
      scrape: {10, :per_minute},
      admin_api: {100, :per_minute}
    ]
  end

  defp whitelisted?(ip) do
    whitelist = Application.get_env(:b1tpoti0n, :rate_limit_whitelist, ["127.0.0.1", "::1"])
    ip in whitelist
  end

  defp rate_limiting_enabled? do
    Application.get_env(:b1tpoti0n, :rate_limiting_enabled, true)
  end
end
