import Config

config :b1tpoti0n, B1tpoti0n.Persistence.Repo,
  database: Path.expand("../priv/b1tpoti0n_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Development-only settings - DO NOT use these values in production
config :b1tpoti0n,
  # Dev admin token for local testing (not secure for production)
  admin_token: "dev_admin_token_change_in_production",
  # Allow all CORS origins in development
  cors_origins: "*",
  # Trust X-Forwarded-For in dev for testing behind local proxies
  trust_x_forwarded_for: true,
  # Allow public access to /stats and /metrics in development
  stats_endpoint: [enabled: true, require_auth: false, ip_whitelist: []],
  metrics_endpoint: [enabled: true, require_auth: false, ip_whitelist: []]

# Allow port override via environment variables for multi-node testing
if http_port = System.get_env("HTTP_PORT") do
  config :b1tpoti0n, http_port: String.to_integer(http_port)
end

if udp_port = System.get_env("UDP_PORT") do
  config :b1tpoti0n, udp_port: String.to_integer(udp_port)
end

config :logger, level: :info
