defmodule B1tpoti0n.Application do
  @moduledoc """
  OTP Application entry point.

  Supervision tree (in startup order):
  1. Repo - Database connection pool
  2. Store.Manager - ETS tables (hydrates passkeys/whitelist from DB)
  3. Registry - Info_hash -> PID mapping for swarm workers (local or distributed)
  4. Swarm.Supervisor - DynamicSupervisor for per-torrent workers (local or distributed)
  5. Stats.Buffer - ETS table for stats aggregation
  6. Stats.Collector - Periodic flush to database
  7. Bandit - HTTP/HTTPS server(s)

  ## Clustering

  When clustering is enabled, libcluster is used for node discovery and
  Horde is used for distributed supervision and registry.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    http_port = Application.get_env(:b1tpoti0n, :http_port, 8080)
    https_port = Application.get_env(:b1tpoti0n, :https_port)
    https_only = Application.get_env(:b1tpoti0n, :https_only, false)
    cluster_enabled = B1tpoti0n.Cluster.enabled?()

    children = [
      # Database connection pool (must start first)
      B1tpoti0n.Persistence.Repo,

      # ETS table owner (hydrates from DB after Repo is ready)
      B1tpoti0n.Store.Manager,

      # Rate limiter (ETS-backed)
      B1tpoti0n.Network.RateLimiter,

      # Metrics (ETS-backed)
      B1tpoti0n.Metrics,

      # WebSocket client registry
      {Registry, keys: :duplicate, name: B1tpoti0n.WebSocket.Registry},

      # Peer connection verifier
      B1tpoti0n.Network.PeerVerifier
    ]

    # Add clustering infrastructure if enabled
    children =
      if cluster_enabled do
        children ++
          [
            # libcluster for node discovery
            {Cluster.Supervisor, [B1tpoti0n.Cluster.topology(), [name: B1tpoti0n.ClusterSupervisor]]},

            # Horde distributed registry for swarm workers
            B1tpoti0n.Swarm.DistributedRegistry,

            # Horde distributed supervisor for swarm workers
            B1tpoti0n.Swarm.DistributedSupervisor
          ]
      else
        children ++
          [
            # Local Registry for info_hash -> PID mapping
            {Registry, keys: :unique, name: B1tpoti0n.Swarm.Registry},

            # Local DynamicSupervisor for swarm workers
            {B1tpoti0n.Swarm.Supervisor, []}
          ]
      end

    # Add Redis cache if enabled
    redis_config = Application.get_env(:b1tpoti0n, :redis, [])
    redis_enabled = Keyword.get(redis_config, :enabled, false)

    children =
      if redis_enabled do
        children ++ [B1tpoti0n.Store.RedisCache]
      else
        children
      end

    children =
      children ++
        [
          # Statistics buffer (ETS-backed)
          B1tpoti0n.Stats.Buffer,

          # Periodic collector (flushes buffer to DB)
          B1tpoti0n.Stats.Collector,

          # Hit-and-Run detector
          B1tpoti0n.Hnr.Detector,

          # Bonus points calculator
          B1tpoti0n.Bonus.Calculator
        ]

    # Add HTTP server unless HTTPS-only mode
    children =
      if https_only and https_port do
        children
      else
        children ++ [{Bandit, scheme: :http, plug: B1tpoti0n.Network.HttpRouter, port: http_port}]
      end

    # Add HTTPS server if configured
    children =
      if https_port do
        certfile = Application.get_env(:b1tpoti0n, :https_certfile)
        keyfile = Application.get_env(:b1tpoti0n, :https_keyfile)

        if certfile && keyfile do
          # TLS hardening: enforce modern TLS versions and secure ciphers
          # Filter TLS 1.2 ciphers to only include ECDHE key exchange (forward secrecy)
          tls12_ciphers =
            :ssl.cipher_suites(:default, :"tlsv1.2")
            |> Enum.filter(fn cipher ->
              key_exchange = Map.get(cipher, :key_exchange)
              key_exchange in [:ecdhe_rsa, :ecdhe_ecdsa]
            end)

          # TLS 1.3 ciphers all have forward secrecy by default
          tls13_ciphers = :ssl.cipher_suites(:default, :"tlsv1.3")

          https_opts = [
            scheme: :https,
            plug: B1tpoti0n.Network.HttpRouter,
            port: https_port,
            certfile: certfile,
            keyfile: keyfile,
            thousand_island_options: [
              transport_options: [
                # Only allow TLS 1.2 and 1.3
                versions: [:"tlsv1.2", :"tlsv1.3"],
                # Use secure cipher suites with forward secrecy
                ciphers: tls13_ciphers ++ tls12_ciphers,
                # Prefer server cipher order
                honor_cipher_order: true,
                # Disable session tickets for forward secrecy
                session_tickets: :disabled
              ]
            ]
          ]

          children ++ [{Bandit, https_opts}]
        else
          Logger.warning("HTTPS port configured but TLS_CERT_PATH or TLS_KEY_PATH missing")
          children
        end
      else
        children
      end

    # Add UDP tracker server if configured (BEP 15)
    udp_port = Application.get_env(:b1tpoti0n, :udp_port)

    children =
      if udp_port do
        children ++ [{B1tpoti0n.Network.UdpServer, [port: udp_port]}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: B1tpoti0n.Supervisor]

    log_startup_banner(http_port, https_port, https_only, udp_port, cluster_enabled)

    Supervisor.start_link(children, opts)
  end

  defp log_startup_banner(http_port, https_port, https_only, udp_port, cluster_enabled) do
    http_line =
      if https_only and https_port do
        "║  HTTP:  disabled (HTTPS-only mode)                       ║"
      else
        "║  HTTP:  http://localhost:#{String.pad_leading(to_string(http_port), 5)}/:passkey/announce       ║"
      end

    https_line =
      if https_port do
        "║  HTTPS: https://localhost:#{String.pad_leading(to_string(https_port), 5)}/:passkey/announce      ║"
      else
        "║  HTTPS: disabled                                         ║"
      end

    udp_line =
      if udp_port do
        "║  UDP:   udp://localhost:#{String.pad_leading(to_string(udp_port), 5)}/announce              ║"
      else
        "║  UDP:   disabled                                         ║"
      end

    cluster_line =
      if cluster_enabled do
        "║  Mode:  CLUSTERED (Horde)                                ║"
      else
        "║  Mode:  standalone                                       ║"
      end

    Logger.info("""

    ╔══════════════════════════════════════════════════════════╗
    ║                    B1tpoti0n Tracker                     ║
    ╠══════════════════════════════════════════════════════════╣
    #{http_line}
    #{https_line}
    #{udp_line}
    #{cluster_line}
    ╚══════════════════════════════════════════════════════════╝
    """)
  end

  @impl true
  def stop(_state) do
    Logger.info("B1tpoti0n shutting down, flushing stats...")
    B1tpoti0n.Stats.Collector.force_flush()
    :ok
  end
end
