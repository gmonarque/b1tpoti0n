import Config

config :b1tpoti0n,
  announce_interval: 1800,
  # Jitter percentage applied to announce interval (0.0-1.0, e.g., 0.1 = ±10%)
  # Helps prevent thundering herd when many peers sync announces
  announce_jitter: 0.1,
  http_port: 8081,
  # HTTPS configuration (disabled by default)
  # Set https_port to enable, or use HTTPS_PORT env var in production
  https_port: nil,
  https_certfile: nil,
  https_keyfile: nil,
  # Set to true to disable HTTP when HTTPS is enabled (HTTPS-only mode)
  https_only: false,
  # If true, only pre-registered torrents are allowed (use Admin.register_torrent/1)
  # If false (default), torrents are auto-registered on first announce
  enforce_torrent_whitelist: false,
  # If true (default), peers must send back the tracker-issued announce key
  # Some clients (Transmission, etc.) may not support this properly
  # Set to false for better client compatibility
  enforce_announce_key: false,
  # Admin API authentication token (set via ADMIN_TOKEN env var in production)
  # If nil or empty, admin API is disabled (returns 503)
  admin_token: "dev_admin_token_change_in_production_please",
  # CORS allowed origins for Admin API
  # "*" = allow all (default, for development)
  # "https://admin.example.com" = single origin
  # ["https://admin.example.com", "https://backup.example.com"] = multiple origins
  cors_origins: "*",
  # Rate limiting configuration
  rate_limiting_enabled: true,
  rate_limits: [
    announce: {30, :per_minute},
    scrape: {10, :per_minute},
    admin_api: {100, :per_minute}
  ],
  # IPs exempt from rate limiting (e.g., monitoring systems)
  rate_limit_whitelist: ["127.0.0.1", "::1"],
  # UDP tracker configuration (BEP 15)
  # Set udp_port to enable UDP tracker, nil to disable
  # WARNING: UDP does not support passkey authentication (BEP 15 limitation).
  # User stats (upload/download) are NOT tracked for UDP announces.
  # Only enable for public tracker mode or hybrid setups.
  udp_port: 8082,
  udp_connection_timeout: 120,
  # Hit-and-Run detection configuration
  # Set to nil to disable HnR checking
  hnr: [
    # 72 hours minimum seedtime required
    min_seedtime: 72 * 3600,
    # Days after completion to meet requirements
    grace_period_days: 14,
    # Warnings before action (disable leeching)
    max_warnings: 3
  ],
  # Ratio enforcement configuration
  # Global minimum ratio
  min_ratio: 0.3,
  # 5GB downloaded before ratio enforced
  ratio_grace_bytes: 5_000_000_000,
  # Bonus points configuration
  # Set to empty list [] to disable bonus points
  bonus_points: [
    # Base points per hour per torrent seeded
    base_points: 1.0,
    # Bytes per point when redeeming (1GB default)
    conversion_rate: 1_000_000_000
  ],
  # Cluster configuration
  # Set enabled: true for multi-node deployments with Horde
  cluster: [
    enabled: true,
    strategy: Cluster.Strategy.Gossip,
    config: [
      port: 45892,
      if_addr: "0.0.0.0",
      multicast_addr: "230.1.1.251",
      multicast_ttl: 1
    ]
  ],
  # Peer storage backend: :memory (default) or :redis
  # Use :redis for multi-node deployments or when peers exceed available RAM
  peer_storage: :memory,
  # Redis cache configuration (optional, for distributed deployments)
  # Set enabled: true to use Redis instead of ETS for shared state
  # Also required when peer_storage: :redis
  redis: [
    enabled: false,
    url: "redis://localhost:6379"
  ],
  # Peer connection verification (tests if peers can accept incoming connections)
  # Connectable peers are returned first in peer lists
  peer_verification: [
    # Set to true to enable verification
    enabled: false,
    # TCP connection timeout in ms
    connect_timeout: 3_000,
    # How long to cache results (seconds)
    cache_ttl: 3600,
    # Maximum concurrent verification attempts
    max_concurrent: 50
  ]

config :b1tpoti0n, ecto_repos: [B1tpoti0n.Persistence.Repo]

# Database adapter: Ecto.Adapters.SQLite3 (default) or Ecto.Adapters.Postgres
# SQLite: Simple, zero-config, good for small/medium deployments
# PostgreSQL: Scalable, recommended for high-traffic or clustered deployments
config :b1tpoti0n, B1tpoti0n.Persistence.Repo, adapter: Ecto.Adapters.SQLite3

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
