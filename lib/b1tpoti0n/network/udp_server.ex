defmodule B1tpoti0n.Network.UdpServer do
  @moduledoc """
  UDP tracker server implementing BEP 15.

  Listens for UDP packets and dispatches to the handler.
  Manages connection_ids with automatic expiration.

  ## Security Features

  - Connection IDs are bound to client IP addresses (BEP 15 compliance)
  - Maximum concurrent packet handlers to prevent DoS
  - Maximum connection ID limit to prevent memory exhaustion
  """
  use GenServer
  require Logger

  alias B1tpoti0n.Core.UdpProtocol
  alias B1tpoti0n.Network.UdpHandler

  @connection_timeout_seconds 120
  @cleanup_interval_ms :timer.minutes(1)
  # SECURITY: Limit concurrent packet handlers to prevent DoS
  @max_concurrent_handlers 100
  # SECURITY: Limit connection IDs to prevent memory exhaustion
  @max_connections 10_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a connection_id is valid for the given client IP.
  Connection IDs are bound to IP addresses per BEP 15 security requirements.
  """
  @spec valid_connection?(non_neg_integer(), tuple()) :: boolean()
  def valid_connection?(connection_id, client_ip) do
    GenServer.call(__MODULE__, {:valid_connection, connection_id, client_ip})
  end

  @doc """
  Generate and register a new connection_id bound to the client IP.
  Returns {:ok, connection_id} or {:error, :too_many_connections}.
  """
  @spec new_connection(tuple()) :: {:ok, non_neg_integer()} | {:error, :too_many_connections}
  def new_connection(client_ip) do
    GenServer.call(__MODULE__, {:new_connection, client_ip})
  end

  @doc """
  Get server statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port) || Application.get_env(:b1tpoti0n, :udp_port, 8080)

    case :gen_udp.open(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("UDP tracker listening on port #{port}")
        schedule_cleanup()

        {:ok,
         %{
           socket: socket,
           port: port,
           # connections: %{connection_id => {client_ip, expires_at}}
           connections: %{},
           packets_received: 0,
           packets_sent: 0,
           # SECURITY: Track active handlers to enforce limit
           active_handlers: 0
         }}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:valid_connection, connection_id, client_ip}, _from, state) do
    # SECURITY: Connection ID must be bound to the requesting IP
    valid =
      case Map.get(state.connections, connection_id) do
        nil ->
          false

        {bound_ip, expires_at} ->
          now = DateTime.utc_now()
          bound_ip == client_ip and DateTime.compare(expires_at, now) == :gt
      end

    {:reply, valid, state}
  end

  @impl true
  def handle_call({:new_connection, client_ip}, _from, state) do
    # SECURITY: Limit total connections to prevent memory exhaustion
    if map_size(state.connections) >= @max_connections do
      {:reply, {:error, :too_many_connections}, state}
    else
      connection_id = UdpProtocol.generate_connection_id()

      timeout =
        Application.get_env(:b1tpoti0n, :udp_connection_timeout, @connection_timeout_seconds)

      expires_at = DateTime.add(DateTime.utc_now(), timeout, :second)

      # SECURITY: Bind connection ID to client IP
      new_connections = Map.put(state.connections, connection_id, {client_ip, expires_at})

      {:reply, {:ok, connection_id}, %{state | connections: new_connections}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      port: state.port,
      active_connections: map_size(state.connections),
      max_connections: @max_connections,
      active_handlers: state.active_handlers,
      max_handlers: @max_concurrent_handlers,
      packets_received: state.packets_received,
      packets_sent: state.packets_sent
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, state) do
    # SECURITY: Limit concurrent packet handlers to prevent DoS
    state =
      if state.active_handlers < @max_concurrent_handlers do
        parent = self()

        # Process packet asynchronously with bounded concurrency
        Task.start(fn ->
          response = UdpHandler.handle_packet(data, ip)

          if response do
            :gen_udp.send(socket, ip, port, response)
          end

          # Notify server that handler completed
          send(parent, :handler_complete)
        end)

        %{state | active_handlers: state.active_handlers + 1}
      else
        # Drop packet when at capacity (DoS protection)
        Logger.warning("UDP handler limit reached, dropping packet from #{:inet.ntoa(ip)}")
        state
      end

    {:noreply, %{state | packets_received: state.packets_received + 1}}
  end

  @impl true
  def handle_info(:handler_complete, state) do
    {:noreply, %{state | active_handlers: max(0, state.active_handlers - 1)}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    new_connections =
      state.connections
      |> Enum.reject(fn {_id, {_client_ip, expires_at}} ->
        DateTime.compare(expires_at, now) != :gt
      end)
      |> Map.new()

    expired_count = map_size(state.connections) - map_size(new_connections)

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired UDP connections")
    end

    schedule_cleanup()
    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end

  # Private

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
