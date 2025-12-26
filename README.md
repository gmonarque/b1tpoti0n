<p align="center">
  <img src="b1tpoti0n.png" alt="b1tpoti0n" width="200">
</p>

# b1tpoti0n

Private BitTorrent tracker in Elixir.

## Why b1tpoti0n?

| | b1tpoti0n | Ocelot (C++) | Chihaya (Go) |
|---|:---:|:---:|:---:|
| Zero-config start | SQLite default | MySQL required | External storage required |
| Private tracker features | Built-in | Requires Gazelle | Middleware plugins |
| Fault tolerance | OTP supervision | Manual | Manual |
| Hot code upgrades | Native | No | No |
| Clustering | Horde + Redis | No | Redis/etcd |
| WebSocket live stats | Built-in | No | No |
| Admin REST API | Built-in | Via Gazelle | No |

**Start simple, scale when needed.** SQLite + in-memory peers for small communities. Swap to PostgreSQL + Redis when you want with config changes only.

**Scalability is built into Elixir.** Elixir runs on the Erlang VM (BEAM), designed for telecom systems handling millions of concurrent connections. Each torrent swarm runs in its own lightweight process. The VM handles scheduling across all CPU cores automatically. When one node isn't enough, just add more! Horde distributes swarm workers across the cluster transparently. See [DOCUMENTATION.md](DOCUMENTATION.md) for details.

**Fault tolerance by default.** OTP supervision trees restart crashed processes automatically. A bug in one swarm doesn't take down the tracker. Hot code upgrades let you deploy fixes without disconnecting peers.

**Batteries included.** HnR detection, bonus points, freeleech, ratio enforcement and client whitelist are all built-in. No separate daemons or plugins to maintain.

## Features

- HTTP/HTTPS tracker (BEP 3)
- UDP tracker (BEP 15) (public mode only, no user auth)
- Passkey authentication
- User ratio tracking
- Client whitelist
- IP banning
- Rate limiting
- Hit-and-Run detection
- Bonus points system
- Freeleech and multipliers
- Prometheus metrics
- SQLite or PostgreSQL database
- In-memory or Redis peer storage
- Optional clustering (Horde + Redis)

## Quick Start

```bash
# Install dependencies
mix deps.get

# Setup database
mix ecto.create && mix ecto.migrate

# Start tracker
iex -S mix
```

Default port: HTTP 8080 (UDP disabled by default, set `udp_port` to enable)

## Endpoints

- `GET /:passkey/announce` - Announce
- `GET /:passkey/scrape` - Scrape
- `GET /health` - Health check
- `GET /stats` - Basic statistics
- `GET /metrics` - Prometheus metrics
- `/admin/*` - Admin REST API
- `GET /ws` - WebSocket (real-time updates)

## Configuration

See `config/config.exs` for all options.

Key settings:
- `http_port` / `https_port` / `udp_port` - Network ports
- `admin_token` - Admin API authentication (required in production)
- `peer_storage` - `:memory` (default) or `:redis` for clustering
- `hnr` - Hit-and-Run detection settings
- `bonus_points` - Bonus points system settings
- `enforce_torrent_whitelist` - Require torrent pre-registration.

For production, set environment variables (see DOCUMENTATION.md):
- `ADMIN_TOKEN`, `HTTP_PORT`, `UDP_PORT`, `DATABASE_URL`, etc.

## Documentation

See [DOCUMENTATION.md](DOCUMENTATION.md) for complete documentation including:
- Full configuration reference
- Architecture overview
- Admin API reference
- Deployment guide

## Admin UI

A standalone admin interface is available at `admin-ui/index.html`.

## Tests

```bash
mix test
```
