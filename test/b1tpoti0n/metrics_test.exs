defmodule B1tpoti0n.MetricsTest do
  @moduledoc """
  Tests for Prometheus metrics collection and export.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Metrics

  setup do
    Metrics.reset()
    :ok
  end

  describe "announce_stop/2" do
    test "increments announce counter" do
      Metrics.announce_stop(%{event: "started"}, 10)
      Metrics.announce_stop(%{event: "completed"}, 20)
      Metrics.announce_stop(%{event: "started"}, 15)

      metrics = Metrics.get_metrics()
      assert metrics.announces_total == 3
    end

    test "tracks by event type" do
      Metrics.announce_stop(%{event: "started"}, 10)
      Metrics.announce_stop(%{event: "started"}, 10)
      Metrics.announce_stop(%{event: "completed"}, 10)

      metrics = Metrics.get_metrics()
      assert metrics.announces_by_event["started"] == 2
      assert metrics.announces_by_event["completed"] == 1
    end

    test "records duration histogram" do
      Metrics.announce_stop(%{}, 100)
      Metrics.announce_stop(%{}, 200)
      Metrics.announce_stop(%{}, 300)

      metrics = Metrics.get_metrics()
      assert metrics.announce_duration.count == 3
      assert metrics.announce_duration.sum == 600
    end
  end

  describe "scrape_stop/2" do
    test "increments scrape counter" do
      Metrics.scrape_stop(%{}, 10)
      Metrics.scrape_stop(%{}, 20)

      metrics = Metrics.get_metrics()
      assert metrics.scrapes_total == 2
    end

    test "records duration histogram" do
      Metrics.scrape_stop(%{}, 50)
      Metrics.scrape_stop(%{}, 150)

      metrics = Metrics.get_metrics()
      assert metrics.scrape_duration.count == 2
      assert metrics.scrape_duration.sum == 200
    end
  end

  describe "error/2" do
    test "increments error counter" do
      Metrics.error(:invalid_passkey)
      Metrics.error(:rate_limited)
      Metrics.error(:invalid_passkey)

      metrics = Metrics.get_metrics()
      assert metrics.errors_total == 3
    end

    test "tracks by error type" do
      Metrics.error(:invalid_passkey)
      Metrics.error(:invalid_passkey)
      Metrics.error(:rate_limited)

      metrics = Metrics.get_metrics()
      assert metrics.errors_by_type[:invalid_passkey] == 2
      assert metrics.errors_by_type[:rate_limited] == 1
    end
  end

  describe "export_prometheus/0" do
    test "returns valid prometheus format" do
      Metrics.announce_stop(%{event: "started"}, 100)
      Metrics.scrape_stop(%{}, 50)
      Metrics.error(:test_error)

      output = Metrics.export_prometheus()

      assert is_binary(output)
      assert output =~ "tracker_announces_total"
      assert output =~ "tracker_scrapes_total"
      assert output =~ "tracker_errors_total"
      assert output =~ "tracker_announce_duration_milliseconds"
      assert output =~ "tracker_users_total"
      assert output =~ "tracker_torrents_total"
    end

    test "includes HELP and TYPE comments" do
      output = Metrics.export_prometheus()

      assert output =~ "# HELP tracker_announces_total"
      assert output =~ "# TYPE tracker_announces_total counter"
    end
  end

  describe "get_metrics/0" do
    test "returns all metric categories" do
      metrics = Metrics.get_metrics()

      assert Map.has_key?(metrics, :announces_total)
      assert Map.has_key?(metrics, :announces_by_event)
      assert Map.has_key?(metrics, :scrapes_total)
      assert Map.has_key?(metrics, :errors_total)
      assert Map.has_key?(metrics, :errors_by_type)
      assert Map.has_key?(metrics, :announce_duration)
      assert Map.has_key?(metrics, :scrape_duration)
      assert Map.has_key?(metrics, :gauges)
    end

    test "gauges include tracker state" do
      metrics = Metrics.get_metrics()

      assert Map.has_key?(metrics.gauges, :users)
      assert Map.has_key?(metrics.gauges, :torrents)
      assert Map.has_key?(metrics.gauges, :swarms)
      assert Map.has_key?(metrics.gauges, :peers)
    end
  end

  describe "reset/0" do
    test "clears all counters" do
      Metrics.announce_stop(%{}, 100)
      Metrics.scrape_stop(%{}, 50)
      Metrics.error(:test)

      Metrics.reset()

      metrics = Metrics.get_metrics()
      assert metrics.announces_total == 0
      assert metrics.scrapes_total == 0
      assert metrics.errors_total == 0
    end
  end
end
