defmodule B1tpoti0n.Metrics do
  @moduledoc """
  Telemetry-based metrics for the BitTorrent tracker.

  ## Events

  The following telemetry events are emitted:

  - `[:b1tpoti0n, :announce, :start]` - Announce request started
  - `[:b1tpoti0n, :announce, :stop]` - Announce request completed
  - `[:b1tpoti0n, :announce, :exception]` - Announce request failed
  - `[:b1tpoti0n, :scrape, :start]` - Scrape request started
  - `[:b1tpoti0n, :scrape, :stop]` - Scrape request completed
  - `[:b1tpoti0n, :error]` - Error occurred

  ## Usage

      # Emit an event
      B1tpoti0n.Metrics.announce_start(%{passkey: passkey})
      B1tpoti0n.Metrics.announce_stop(%{passkey: passkey, event: event}, duration_ms)

  ## Prometheus Format

      B1tpoti0n.Metrics.export_prometheus()
  """
  use GenServer
  require Logger

  @table :b1tpoti0n_metrics

  # Counter keys
  @announces_total :announces_total
  @announces_by_event :announces_by_event
  @scrapes_total :scrapes_total
  @errors_total :errors_total
  @errors_by_type :errors_by_type

  # Histogram keys
  @announce_duration :announce_duration
  @scrape_duration :scrape_duration

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record an announce request start.
  """
  def announce_start(metadata \\ %{}) do
    :telemetry.execute(
      [:b1tpoti0n, :announce, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Record an announce request completion.
  """
  def announce_stop(metadata \\ %{}, duration_ms) do
    increment(@announces_total, 1)

    if event = Map.get(metadata, :event) do
      increment({@announces_by_event, event}, 1)
    end

    record_histogram(@announce_duration, duration_ms)

    :telemetry.execute(
      [:b1tpoti0n, :announce, :stop],
      %{duration: duration_ms, system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Record a scrape request completion.
  """
  def scrape_stop(metadata \\ %{}, duration_ms) do
    increment(@scrapes_total, 1)
    record_histogram(@scrape_duration, duration_ms)

    :telemetry.execute(
      [:b1tpoti0n, :scrape, :stop],
      %{duration: duration_ms, system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Record an error.
  """
  def error(type, metadata \\ %{}) do
    increment(@errors_total, 1)
    increment({@errors_by_type, type}, 1)

    :telemetry.execute(
      [:b1tpoti0n, :error],
      %{system_time: System.system_time()},
      Map.put(metadata, :type, type)
    )
  end

  @doc """
  Get current metrics as a map.
  """
  def get_metrics do
    %{
      announces_total: get_counter(@announces_total),
      announces_by_event: get_labeled_counters(@announces_by_event),
      scrapes_total: get_counter(@scrapes_total),
      errors_total: get_counter(@errors_total),
      errors_by_type: get_labeled_counters(@errors_by_type),
      announce_duration: get_histogram(@announce_duration),
      scrape_duration: get_histogram(@scrape_duration),
      gauges: get_gauges()
    }
  end

  @doc """
  Export metrics in Prometheus text format.
  Uses configurable namespace to avoid fingerprinting (default: "tracker").
  Configure via: config :b1tpoti0n, metrics_namespace: "my_tracker"
  """
  def export_prometheus do
    # SECURITY: Use generic namespace to prevent fingerprinting
    ns = Application.get_env(:b1tpoti0n, :metrics_namespace, "tracker")
    metrics = get_metrics()
    gauges = metrics.gauges

    lines = [
      # Counters
      "# HELP #{ns}_announces_total Total number of announce requests",
      "# TYPE #{ns}_announces_total counter",
      "#{ns}_announces_total #{metrics.announces_total}",
      "",
      "# HELP #{ns}_announces_by_event Announces by event type",
      "# TYPE #{ns}_announces_by_event counter",
      format_labeled_counter("#{ns}_announces_by_event", "event", metrics.announces_by_event),
      "",
      "# HELP #{ns}_scrapes_total Total number of scrape requests",
      "# TYPE #{ns}_scrapes_total counter",
      "#{ns}_scrapes_total #{metrics.scrapes_total}",
      "",
      "# HELP #{ns}_errors_total Total number of errors",
      "# TYPE #{ns}_errors_total counter",
      "#{ns}_errors_total #{metrics.errors_total}",
      "",
      "# HELP #{ns}_errors_by_type Errors by type",
      "# TYPE #{ns}_errors_by_type counter",
      format_labeled_counter("#{ns}_errors_by_type", "type", metrics.errors_by_type),
      "",
      # Histograms (simplified - just sum and count)
      "# HELP #{ns}_announce_duration_milliseconds Announce request duration",
      "# TYPE #{ns}_announce_duration_milliseconds summary",
      format_histogram("#{ns}_announce_duration_milliseconds", metrics.announce_duration),
      "",
      "# HELP #{ns}_scrape_duration_milliseconds Scrape request duration",
      "# TYPE #{ns}_scrape_duration_milliseconds summary",
      format_histogram("#{ns}_scrape_duration_milliseconds", metrics.scrape_duration),
      "",
      # Gauges
      "# HELP #{ns}_users_total Total number of registered users",
      "# TYPE #{ns}_users_total gauge",
      "#{ns}_users_total #{gauges.users}",
      "",
      "# HELP #{ns}_torrents_total Total number of registered torrents",
      "# TYPE #{ns}_torrents_total gauge",
      "#{ns}_torrents_total #{gauges.torrents}",
      "",
      "# HELP #{ns}_swarms_active Number of active swarm workers",
      "# TYPE #{ns}_swarms_active gauge",
      "#{ns}_swarms_active #{gauges.swarms}",
      "",
      "# HELP #{ns}_peers_active Number of active peers in memory",
      "# TYPE #{ns}_peers_active gauge",
      "#{ns}_peers_active #{gauges.peers}",
      "",
      "# HELP #{ns}_passkeys_cached Number of passkeys in cache",
      "# TYPE #{ns}_passkeys_cached gauge",
      "#{ns}_passkeys_cached #{gauges.passkeys_cached}",
      "",
      "# HELP #{ns}_banned_ips Number of banned IPs",
      "# TYPE #{ns}_banned_ips gauge",
      "#{ns}_banned_ips #{gauges.banned_ips}",
      ""
    ]

    Enum.join(lines, "\n")
  end

  @doc """
  Reset all metrics (useful for testing).
  """
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])

    # Initialize counters
    :ets.insert(@table, {@announces_total, 0})
    :ets.insert(@table, {@scrapes_total, 0})
    :ets.insert(@table, {@errors_total, 0})

    # Initialize histograms (sum and count)
    :ets.insert(@table, {{@announce_duration, :sum}, 0})
    :ets.insert(@table, {{@announce_duration, :count}, 0})
    :ets.insert(@table, {{@scrape_duration, :sum}, 0})
    :ets.insert(@table, {{@scrape_duration, :count}, 0})

    Logger.debug("Metrics started with table #{inspect(table)}")
    {:ok, %{table: table}}
  end

  # --- Private Helpers ---

  defp increment(key, amount) do
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
  rescue
    ArgumentError -> :ets.insert(@table, {key, amount})
  end

  defp record_histogram(key, value) do
    :ets.update_counter(@table, {key, :sum}, {2, value}, {{key, :sum}, 0})
    :ets.update_counter(@table, {key, :count}, {2, 1}, {{key, :count}, 0})
  rescue
    ArgumentError ->
      :ets.insert(@table, {{key, :sum}, value})
      :ets.insert(@table, {{key, :count}, 1})
  end

  defp get_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp get_labeled_counters(prefix) do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{^prefix, _label}, _value} -> true
      _ -> false
    end)
    |> Enum.map(fn {{^prefix, label}, value} -> {label, value} end)
    |> Map.new()
  end

  defp get_histogram(key) do
    sum =
      case :ets.lookup(@table, {key, :sum}) do
        [{{^key, :sum}, v}] -> v
        [] -> 0
      end

    count =
      case :ets.lookup(@table, {key, :count}) do
        [{{^key, :count}, v}] -> v
        [] -> 0
      end

    %{sum: sum, count: count}
  end

  defp get_gauges do
    alias B1tpoti0n.Persistence.Repo
    alias B1tpoti0n.Persistence.Schemas.{User, Torrent}

    ets_stats = B1tpoti0n.Store.Manager.stats()

    %{
      users: Repo.aggregate(User, :count) || 0,
      torrents: Repo.aggregate(Torrent, :count) || 0,
      swarms: B1tpoti0n.Swarm.count_workers(),
      peers: count_active_peers(),
      passkeys_cached: ets_stats.passkeys,
      banned_ips: ets_stats.banned_ips
    }
  end

  defp count_active_peers do
    B1tpoti0n.Swarm.list_torrents()
    |> Enum.reduce(0, fn info_hash, acc ->
      case B1tpoti0n.Swarm.lookup_worker(info_hash) do
        {:ok, pid} ->
          try do
            {:ok, count} = GenServer.call(pid, :peer_count, 1000)
            acc + count
          catch
            :exit, _ -> acc
          end

        :error ->
          acc
      end
    end)
  end

  defp format_labeled_counter(name, label_name, labels) do
    labels
    |> Enum.map(fn {label, value} ->
      "#{name}{#{label_name}=\"#{label}\"} #{value}"
    end)
    |> Enum.join("\n")
  end

  defp format_histogram(name, %{sum: sum, count: count}) do
    avg = if count > 0, do: Float.round(sum / count, 2), else: 0

    """
    #{name}_sum #{sum}
    #{name}_count #{count}
    #{name}_avg #{avg}
    """
    |> String.trim()
  end
end
