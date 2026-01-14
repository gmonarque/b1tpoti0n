defmodule B1tpoti0n.Core.ParserTest do
  @moduledoc """
  Tests for Core.Parser - HTTP tracker protocol parsing.
  """
  use ExUnit.Case, async: true

  alias B1tpoti0n.Core.Parser

  defp valid_params do
    %{
      "info_hash" => :crypto.strong_rand_bytes(20),
      "peer_id" => "-TR3000-" <> :crypto.strong_rand_bytes(12),
      "port" => "6881",
      "uploaded" => "1000",
      "downloaded" => "500",
      "left" => "100000"
    }
  end

  describe "parse_http_announce/3" do
    test "parses valid announce request" do
      params = valid_params()
      passkey = "testpasskey123456789012345678901"
      remote_ip = {192, 168, 1, 100}

      assert {:ok, request} = Parser.parse_http_announce(params, passkey, remote_ip)

      assert request.info_hash == params["info_hash"]
      assert request.peer_id == params["peer_id"]
      assert request.port == 6881
      assert request.uploaded == 1000
      assert request.downloaded == 500
      assert request.left == 100_000
      assert request.passkey == passkey
      assert request.ip == remote_ip
    end

    test "parses event parameter" do
      base_params = valid_params()

      # Started event
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "event", "started"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.event == :started

      # Completed event
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "event", "completed"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.event == :completed

      # Stopped event
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "event", "stopped"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.event == :stopped

      # No event (default)
      {:ok, request} =
        Parser.parse_http_announce(
          base_params,
          nil,
          {127, 0, 0, 1}
        )

      assert request.event == :none
    end

    test "parses numwant parameter" do
      base_params = valid_params()

      # Explicit numwant
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "numwant", "100"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.num_want == 100

      # Default numwant
      {:ok, request} =
        Parser.parse_http_announce(
          base_params,
          nil,
          {127, 0, 0, 1}
        )

      assert request.num_want == 50
    end

    test "clamps numwant to valid range" do
      base_params = valid_params()

      # Too high
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "numwant", "500"),
          nil,
          {127, 0, 0, 1}
        )

      # Falls back to default
      assert request.num_want == 50

      # Negative
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "numwant", "-10"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.num_want == 50

      # Zero
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "numwant", "0"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.num_want == 50
    end

    test "parses compact flag" do
      base_params = valid_params()

      # Compact enabled (default)
      {:ok, request} = Parser.parse_http_announce(base_params, nil, {127, 0, 0, 1})
      assert request.compact == true

      # Compact explicitly enabled
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "compact", "1"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.compact == true

      # Compact disabled
      {:ok, request} =
        Parser.parse_http_announce(
          Map.put(base_params, "compact", "0"),
          nil,
          {127, 0, 0, 1}
        )

      assert request.compact == false
    end

    test "returns error for missing info_hash" do
      params = valid_params() |> Map.delete("info_hash")

      assert {:error, "missing info_hash"} =
               Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for invalid info_hash length" do
      params = valid_params() |> Map.put("info_hash", "tooshort")

      assert {:error, msg} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
      assert msg =~ "invalid info_hash length"
    end

    test "returns error for missing peer_id" do
      params = valid_params() |> Map.delete("peer_id")

      assert {:error, "missing peer_id"} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for invalid peer_id length" do
      params = valid_params() |> Map.put("peer_id", "short")

      assert {:error, msg} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
      assert msg =~ "invalid peer_id length"
    end

    test "returns error for missing port" do
      params = valid_params() |> Map.delete("port")

      assert {:error, "missing port"} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for invalid port" do
      params = valid_params() |> Map.put("port", "notanumber")

      assert {:error, "invalid port"} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for negative port" do
      params = valid_params() |> Map.put("port", "-100")

      assert {:error, "invalid port"} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for missing uploaded" do
      params = valid_params() |> Map.delete("uploaded")

      assert {:error, "missing uploaded"} =
               Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for missing downloaded" do
      params = valid_params() |> Map.delete("downloaded")

      assert {:error, "missing downloaded"} =
               Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "returns error for missing left" do
      params = valid_params() |> Map.delete("left")

      assert {:error, "missing left"} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
    end

    test "accepts integer values for stats" do
      params = %{
        "info_hash" => :crypto.strong_rand_bytes(20),
        "peer_id" => :crypto.strong_rand_bytes(20),
        # Integer
        "port" => 6881,
        # Integer
        "uploaded" => 1000,
        # Integer
        "downloaded" => 500,
        # Integer
        "left" => 100_000
      }

      assert {:ok, request} = Parser.parse_http_announce(params, nil, {127, 0, 0, 1})
      assert request.port == 6881
      assert request.uploaded == 1000
    end
  end
end
