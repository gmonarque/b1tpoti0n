defmodule B1tpoti0n.Network.RateLimiterTest do
  @moduledoc """
  Tests for IP-based rate limiting.
  """
  use ExUnit.Case, async: false

  alias B1tpoti0n.Network.RateLimiter

  setup do
    RateLimiter.reset("test_ip")
    RateLimiter.reset("192.168.1.1")
    :ok
  end

  describe "check/2" do
    test "allows requests under the limit" do
      for _ <- 1..10 do
        assert :ok = RateLimiter.check("test_ip", :announce)
      end
    end

    test "blocks requests over the limit" do
      for _ <- 1..30 do
        RateLimiter.check("192.168.1.1", :announce)
      end

      assert {:error, :rate_limited, retry_after} = RateLimiter.check("192.168.1.1", :announce)
      assert is_integer(retry_after)
      assert retry_after >= 0
    end

    test "different IPs have separate limits" do
      for _ <- 1..30 do
        RateLimiter.check("10.0.0.1", :announce)
      end

      assert :ok = RateLimiter.check("10.0.0.2", :announce)
    end

    test "different limit types have separate limits" do
      for _ <- 1..30 do
        RateLimiter.check("test_ip", :announce)
      end

      assert :ok = RateLimiter.check("test_ip", :scrape)
    end
  end

  describe "reset/1" do
    test "resets all limits for an IP" do
      for _ <- 1..30 do
        RateLimiter.check("test_ip", :announce)
      end

      assert {:error, :rate_limited, _} = RateLimiter.check("test_ip", :announce)

      RateLimiter.reset("test_ip")

      assert :ok = RateLimiter.check("test_ip", :announce)
    end
  end

  describe "reset/2" do
    test "resets specific limit type for an IP" do
      for _ <- 1..30 do
        RateLimiter.check("test_ip", :announce)
      end

      for _ <- 1..10 do
        RateLimiter.check("test_ip", :scrape)
      end

      RateLimiter.reset("test_ip", :announce)

      assert :ok = RateLimiter.check("test_ip", :announce)
      assert {:error, :rate_limited, _} = RateLimiter.check("test_ip", :scrape)
    end
  end

  describe "get_state/1" do
    test "returns current rate limit state" do
      for _ <- 1..5 do
        RateLimiter.check("test_ip", :announce)
      end

      state = RateLimiter.get_state("test_ip")

      assert is_map(state)
      assert Map.has_key?(state, :announce)
      assert state.announce.count == 5
      assert state.announce.remaining == 25
    end
  end

  describe "stats/0" do
    test "returns overall statistics" do
      stats = RateLimiter.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :entries)
      assert Map.has_key?(stats, :memory_bytes)
    end
  end

  describe "whitelist" do
    test "whitelisted IPs are not rate limited" do
      for _ <- 1..100 do
        assert :ok = RateLimiter.check("127.0.0.1", :announce)
      end
    end
  end
end
