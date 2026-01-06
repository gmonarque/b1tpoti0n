import Config

config :b1tpoti0n, B1tpoti0n.Persistence.Repo,
  database: Path.expand("../priv/b1tpoti0n_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Allow port override via environment variables for multi-node testing
if http_port = System.get_env("HTTP_PORT") do
  config :b1tpoti0n, http_port: String.to_integer(http_port)
end

if udp_port = System.get_env("UDP_PORT") do
  config :b1tpoti0n, udp_port: String.to_integer(udp_port)
end

config :logger, level: :info
