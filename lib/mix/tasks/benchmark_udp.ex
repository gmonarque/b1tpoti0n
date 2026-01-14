defmodule Mix.Tasks.BenchmarkUdp do
  @moduledoc """
  Run a UDP tracker performance benchmark.

  ## Usage

      # Start tracker with UDP enabled first:
      # config :b1tpoti0n, udp_port: 8081
      iex -S mix

      # Then run benchmark:
      mix benchmark_udp

      # With options:
      mix benchmark_udp --clients 100 --duration 30 --port 8081

  ## Options

    * `--clients` - Number of concurrent clients (default: 50)
    * `--duration` - Test duration in seconds (default: 10)
    * `--port` - Tracker UDP port (default: 8081)
    * `--host` - Tracker host (default: 127.0.0.1)
  """
  use Mix.Task

  @shortdoc "Run UDP tracker performance benchmark"

  @default_clients 50
  @default_duration 10
  @default_port 8081
  @default_host "127.0.0.1"

  # UDP protocol constants (BEP 15)
  @connect_action 0
  @announce_action 1

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

    {:ok, host_ip} = :inet.parse_address(String.to_charlist(host))

    IO.puts("\n=== b1tpoti0n UDP Benchmark ===\n")
    IO.puts("Target: udp://#{host}:#{port}")
    IO.puts("Clients: #{clients}")
    IO.puts("Duration: #{duration}s")
    IO.puts("")

    # Generate test data
    info_hashes = for _ <- 1..10, do: :crypto.strong_rand_bytes(20)

    IO.puts("Starting benchmark...\n")

    # Spawn client processes
    parent = self()
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration * 1000

    clients_pids =
      for client_id <- 1..clients do
        spawn_link(fn ->
          run_client(parent, client_id, host_ip, port, info_hashes, end_time)
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

  defp run_client(parent, _client_id, host_ip, port, info_hashes, end_time) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    # Get connection ID first
    case connect(socket, host_ip, port) do
      {:ok, connection_id} ->
        peer_id = :crypto.strong_rand_bytes(20)

        result =
          run_announces(
            socket,
            host_ip,
            port,
            connection_id,
            info_hashes,
            peer_id,
            end_time,
            0,
            0,
            []
          )

        :gen_udp.close(socket)
        send(parent, {:done, self(), result})

      {:error, _reason} ->
        :gen_udp.close(socket)
        send(parent, {:done, self(), %{requests: 0, errors: 1, latencies: []}})
    end
  end

  defp connect(socket, host_ip, port) do
    transaction_id = :rand.uniform(0xFFFFFFFF)

    # Connect request: connection_id (magic) + action + transaction_id
    request = <<0x41727101980::64, @connect_action::32, transaction_id::32>>

    :gen_udp.send(socket, host_ip, port, request)

    case :gen_udp.recv(socket, 0, 2000) do
      {:ok, {_, _, <<@connect_action::32, ^transaction_id::32, connection_id::64>>}} ->
        {:ok, connection_id}

      {:ok, {_, _, _other}} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_announces(
         socket,
         host_ip,
         port,
         connection_id,
         info_hashes,
         peer_id,
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

      result = send_announce(socket, host_ip, port, connection_id, info_hash, peer_id, requests)

      latency = (System.monotonic_time(:microsecond) - start) / 1000

      case result do
        :ok ->
          run_announces(
            socket,
            host_ip,
            port,
            connection_id,
            info_hashes,
            peer_id,
            end_time,
            requests + 1,
            errors,
            [latency | latencies]
          )

        :error ->
          run_announces(
            socket,
            host_ip,
            port,
            connection_id,
            info_hashes,
            peer_id,
            end_time,
            requests + 1,
            errors + 1,
            latencies
          )
      end
    end
  end

  defp send_announce(socket, host_ip, port, connection_id, info_hash, peer_id, uploaded) do
    transaction_id = :rand.uniform(0xFFFFFFFF)
    client_port = Enum.random(6881..6999)

    # Announce request per BEP 15
    request = <<
      connection_id::64,
      @announce_action::32,
      transaction_id::32,
      info_hash::binary-size(20),
      peer_id::binary-size(20),
      # downloaded
      uploaded * 1000::64,
      # left
      1_000_000_000::64,
      # uploaded
      0::64,
      # event (none)
      0::32,
      # IP (default)
      0::32,
      # key
      0::32,
      # num_want
      50::32-signed,
      client_port::16
    >>

    :gen_udp.send(socket, host_ip, port, request)

    case :gen_udp.recv(socket, 0, 2000) do
      {:ok, {_, _, <<@announce_action::32, ^transaction_id::32, _rest::binary>>}} ->
        :ok

      {:ok, {_, _, <<3::32, ^transaction_id::32, _error::binary>>}} ->
        # Error response but tracker is working
        :ok

      {:ok, {_, _, _other}} ->
        :error

      {:error, :timeout} ->
        :error

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
end
