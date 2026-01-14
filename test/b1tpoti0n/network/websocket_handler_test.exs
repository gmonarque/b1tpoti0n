defmodule B1tpoti0n.Network.WebSocketHandlerTest do
  @moduledoc """
  Tests for WebSocket handler for real-time tracker updates.
  """
  use ExUnit.Case, async: false

  alias B1tpoti0n.Network.WebSocketHandler
  alias B1tpoti0n.Persistence.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "init/1" do
    test "initializes with default subscriptions" do
      {:ok, state} = WebSocketHandler.init([])

      assert state.subscriptions == [:stats]
    end

    test "initializes with custom subscriptions" do
      {:ok, state} = WebSocketHandler.init(subscriptions: [:stats, :swarm])

      assert :stats in state.subscriptions
      assert :swarm in state.subscriptions
    end
  end

  describe "handle_in/2" do
    setup do
      {:ok, state} = WebSocketHandler.init(subscriptions: [:stats])
      {:ok, state: state}
    end

    test "handles subscribe message", %{state: state} do
      message = Jason.encode!(%{type: "subscribe", events: ["swarm", "announce"]})

      {:ok, new_state} = WebSocketHandler.handle_in({message, [opcode: :text]}, state)

      assert :stats in new_state.subscriptions
      assert :swarm in new_state.subscriptions
      assert :announce in new_state.subscriptions
    end

    test "handles unsubscribe message", %{state: state} do
      # First subscribe to more events
      state = %{state | subscriptions: [:stats, :swarm, :announce]}

      message = Jason.encode!(%{type: "unsubscribe", events: ["swarm"]})

      {:ok, new_state} = WebSocketHandler.handle_in({message, [opcode: :text]}, state)

      assert :stats in new_state.subscriptions
      refute :swarm in new_state.subscriptions
      assert :announce in new_state.subscriptions
    end

    test "handles ping message", %{state: state} do
      message = Jason.encode!(%{type: "ping"})

      {:push, {:text, response}, ^state} =
        WebSocketHandler.handle_in({message, [opcode: :text]}, state)

      decoded = Jason.decode!(response)
      assert decoded["type"] == "pong"
      assert is_binary(decoded["timestamp"])
    end

    test "handles get_stats message", %{state: state} do
      message = Jason.encode!(%{type: "get_stats"})

      {:push, {:text, response}, ^state} =
        WebSocketHandler.handle_in({message, [opcode: :text]}, state)

      decoded = Jason.decode!(response)
      assert decoded["type"] == "stats"
      assert is_map(decoded["payload"])
    end

    test "handles get_swarms message", %{state: state} do
      message = Jason.encode!(%{type: "get_swarms"})

      {:push, {:text, response}, ^state} =
        WebSocketHandler.handle_in({message, [opcode: :text]}, state)

      decoded = Jason.decode!(response)
      assert decoded["type"] == "swarms"
      assert is_list(decoded["payload"])
    end

    test "ignores invalid JSON", %{state: state} do
      {:ok, ^state} = WebSocketHandler.handle_in({"invalid json", [opcode: :text]}, state)
    end

    test "ignores binary messages", %{state: state} do
      {:ok, ^state} = WebSocketHandler.handle_in({<<1, 2, 3>>, [opcode: :binary]}, state)
    end
  end

  describe "handle_info/2" do
    setup do
      {:ok, state} = WebSocketHandler.init(subscriptions: [:stats])
      {:ok, state: state}
    end

    test "sends stats on :send_stats when subscribed", %{state: state} do
      {:push, {:text, response}, _new_state} = WebSocketHandler.handle_info(:send_stats, state)

      decoded = Jason.decode!(response)
      assert decoded["type"] == "stats"
      assert is_map(decoded["payload"])
    end

    test "skips stats on :send_stats when not subscribed" do
      {:ok, state} = WebSocketHandler.init(subscriptions: [:swarm])

      {:ok, _new_state} = WebSocketHandler.handle_info(:send_stats, state)
    end

    test "broadcasts message when subscribed to event type", %{state: state} do
      message = %{type: :stats, payload: %{test: true}}

      {:push, {:text, response}, ^state} =
        WebSocketHandler.handle_info({:broadcast, message}, state)

      decoded = Jason.decode!(response)
      assert decoded["type"] == "stats"
      assert decoded["payload"]["test"] == true
    end

    test "ignores broadcast when not subscribed to event type", %{state: state} do
      message = %{type: :swarm, payload: %{test: true}}

      {:ok, ^state} = WebSocketHandler.handle_info({:broadcast, message}, state)
    end

    test "ignores unknown messages", %{state: state} do
      {:ok, ^state} = WebSocketHandler.handle_info(:unknown_message, state)
    end
  end

  describe "broadcast/1" do
    test "broadcasts to all registered clients" do
      # Register this process as a client
      Registry.register(WebSocketHandler.registry_name(), :clients, %{})

      message = %{type: :test, payload: "hello"}
      :ok = WebSocketHandler.broadcast(message)

      assert_receive {:broadcast, ^message}
    end
  end

  describe "client_count/0" do
    test "returns count of registered clients" do
      # Initially might have some clients from init
      initial = WebSocketHandler.client_count()

      # Register this process
      Registry.register(WebSocketHandler.registry_name(), :clients, %{})

      assert WebSocketHandler.client_count() == initial + 1
    end
  end
end
