defmodule Mix.Tasks.Benchmark do
  @moduledoc """
  Run a simple performance benchmark against the tracker.

  ## Usage

      # Start tracker first in another terminal:
      iex -S mix

      # Then run benchmark:
      mix benchmark

      # With options:
      mix benchmark --clients 100 --duration 30 --port 8080

  ## Options

    * `--clients` - Number of concurrent clients (default: 50)
    * `--duration` - Test duration in seconds (default: 10)
    * `--port` - Tracker HTTP port (default: 8080)
    * `--host` - Tracker host (default: 127.0.0.1)
  """
  use Mix.Task

  @shortdoc "Run tracker performance benchmark"

  @default_clients 50
  @default_duration 10
  @default_port 8080
  @default_host "127.0.0.1"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [clients: :integer, duration: :integer, port: :integer, host: :string]
      )

    clients = opts[:clients] || @default_clients
    duration = opts[:duration] || @default_duration
    port = opts[:port] || @default_port
    host = opts[:host] || @default_host

    # Start required applications
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    IO.puts("\n=== b1tpoti0n Benchmark ===\n")
    IO.puts("Target: http://#{host}:#{port}")
    IO.puts("Clients: #{clients}")
    IO.puts("Duration: #{duration}s")
    IO.puts("")

    # Generate test data
    passkey = generate_passkey()
    info_hashes = for _ <- 1..10, do: :crypto.strong_rand_bytes(20)

    IO.puts("Starting benchmark...\n")

    # Spawn client processes
    parent = self()
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration * 1000

    clients_pids =
      for client_id <- 1..clients do
        spawn_link(fn ->
          run_client(parent, client_id, host, port, passkey, info_hashes, end_time)
        end)
      end

    # Collect results
    results = collect_results(clients_pids, [])
    total_time = System.monotonic_time(:millisecond) - start_time

    # Calculate stats
    total_requests = Enum.sum(Enum.map(results, & &1.requests))
    total_errors = Enum.sum(Enum.map(results, & &1.errors))
    all_latencies = Enum.flat_map(results, & &1.latencies)

    rps = total_requests / (total_time / 1000)

    IO.puts("=== Results ===\n")
    IO.puts("Total requests: #{total_requests}")
    IO.puts("Total errors: #{total_errors}")
    IO.puts("Duration: #{Float.round(total_time / 1000, 2)}s")
    IO.puts("Throughput: #{Float.round(rps, 2)} req/s")

    if length(all_latencies) > 0 do
      sorted = Enum.sort(all_latencies)
      avg = Enum.sum(sorted) / length(sorted)
      p50 = percentile(sorted, 50)
      p95 = percentile(sorted, 95)
      p99 = percentile(sorted, 99)
      max_lat = List.last(sorted)

      IO.puts("\nLatency (ms):")
      IO.puts("  avg: #{Float.round(avg, 2)}")
      IO.puts("  p50: #{Float.round(p50, 2)}")
      IO.puts("  p95: #{Float.round(p95, 2)}")
      IO.puts("  p99: #{Float.round(p99, 2)}")
      IO.puts("  max: #{Float.round(max_lat, 2)}")
    end

    IO.puts("")
  end

  defp run_client(parent, _client_id, host, port, passkey, info_hashes, end_time) do
    peer_id = :crypto.strong_rand_bytes(20)
    client_port = Enum.random(6881..6999)

    ip =
      "#{Enum.random(1..254)}.#{Enum.random(1..254)}.#{Enum.random(1..254)}.#{Enum.random(1..254)}"

    result =
      run_requests(host, port, passkey, info_hashes, peer_id, client_port, ip, end_time, 0, 0, [])

    send(parent, {:done, self(), result})
  end

  defp run_requests(
         host,
         port,
         passkey,
         info_hashes,
         peer_id,
         client_port,
         ip,
         end_time,
         requests,
         errors,
         latencies
       ) do
    if System.monotonic_time(:millisecond) >= end_time do
      %{requests: requests, errors: errors, latencies: latencies}
    else
      info_hash = Enum.random(info_hashes)
      start = System.monotonic_time(:microsecond)

      result = send_announce(host, port, passkey, info_hash, peer_id, client_port, ip, requests)

      latency = (System.monotonic_time(:microsecond) - start) / 1000

      case result do
        :ok ->
          run_requests(
            host,
            port,
            passkey,
            info_hashes,
            peer_id,
            client_port,
            ip,
            end_time,
            requests + 1,
            errors,
            [latency | latencies]
          )

        :error ->
          run_requests(
            host,
            port,
            passkey,
            info_hashes,
            peer_id,
            client_port,
            ip,
            end_time,
            requests + 1,
            errors + 1,
            latencies
          )
      end
    end
  end

  defp send_announce(host, port, passkey, info_hash, peer_id, client_port, ip, uploaded) do
    query =
      URI.encode_query(%{
        "info_hash" => info_hash,
        "peer_id" => peer_id,
        "port" => client_port,
        "uploaded" => uploaded * 1000,
        "downloaded" => 0,
        "left" => 1_000_000_000,
        "compact" => 1,
        "ip" => ip
      })

    url = ~c"http://#{host}:#{port}/#{passkey}/announce?#{query}"

    case :httpc.request(:get, {url, []}, [timeout: 5000, connect_timeout: 2000], []) do
      {:ok, {{_, 200, _}, _, _body}} ->
        :ok

      {:ok, {{_, code, _}, _, _}} ->
        # Non-200 responses (like missing passkey) still count as "working"
        if code in [200, 400, 403] do
          :ok
        else
          :error
        end

      {:error, _} ->
        :error
    end
  end

  defp collect_results([], results), do: results

  defp collect_results(pids, results) do
    receive do
      {:done, pid, result} ->
        collect_results(List.delete(pids, pid), [result | results])
    after
      30_000 ->
        IO.puts("Warning: timeout waiting for clients")
        results
    end
  end

  defp percentile(sorted_list, p) do
    k = (length(sorted_list) - 1) * p / 100
    f = floor(k)
    c = ceil(k)

    if f == c do
      Enum.at(sorted_list, trunc(f))
    else
      lower = Enum.at(sorted_list, trunc(f))
      upper = Enum.at(sorted_list, trunc(c))
      lower + (upper - lower) * (k - f)
    end
  end

  defp generate_passkey do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
