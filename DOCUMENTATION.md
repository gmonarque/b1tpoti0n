# b1tpoti0n Documentation

Private BitTorrent tracker in Elixir supporting HTTP (BEP 3) and UDP (BEP 15) protocols.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Tracker Protocol](#tracker-protocol)
- [Admin API](#admin-api)
- [Deployment](#deployment)

---

## Features

### Core Tracker
- HTTP announce/scrape (BEP 3)
- UDP announce/scrape (BEP 15)
- Compact peer responses (BEP 23)
- IPv4 and IPv6 support
- Passkey-based authentication (private tracker)

### User Management
- Per-user upload/download tracking
- Ratio enforcement with configurable minimum
- Leech permission control
- Passkey generation and reset

### Torrent Management
- Torrent whitelist enforcement (optional)
- Per-torrent freeleech
- Upload/download multipliers
- Seeder/leecher counts per swarm

### Anti-Abuse
- Client whitelist (by peer_id prefix)
- IP banning with optional expiration and CIDR support
- Rate limiting (token bucket per IP)
- Hit-and-Run detection
- Peer connection verification (with private IP range blocking)
- Port validation (blocks privileged ports and invalid ranges)
- Multiplier caps (max 10x upload, max 1x download) to prevent abuse

### Bonus System
- Points earned based on seeding time and ratio
- Configurable earning rates
- Points redeemable for upload credit

### Performance & Scalability
- ETS-based in-memory caching
- Buffered stats writes to reduce DB load
- Per-torrent GenServer swarm workers
- Prometheus metrics export
- Optional Redis peer storage for millions of peers
- SQLite or PostgreSQL database support

### Clustering (Optional)
- Horde distributed supervision
- libcluster node discovery (Gossip, EPMD, Kubernetes strategies)
- Redis distributed cache and peer storage

### Security
- TLS 1.2+ with secure cipher suites and forward secrecy
- Admin API IP whitelist
- Stats/metrics endpoint protection (auth or IP whitelist)
- X-Forwarded-For trust configuration (for reverse proxy setups)
- Constant-time token comparison (timing attack prevention)
- Private IP blocking in peer verification (SSRF prevention)

---

## Installation

### Requirements
- Elixir >= 1.15
- Erlang/OTP >= 24
- SQLite3 or PostgreSQL 12+

### Setup

```bash
# Install dependencies
mix deps.get

# Create database and run migrations
mix ecto.create
mix ecto.migrate

# Run tests
mix test

# Start server
iex -S mix
```

---

## Configuration

### Config File Structure

b1tpoti0n uses Elixir's standard configuration system:

| File | Purpose | When to edit |
|------|---------|--------------|
| `config/config.exs` | Base defaults | Rarely - contains sensible defaults |
| `config/dev.exs` | Development overrides | Local development tweaks |
| `config/prod.exs` | Production overrides | Production-specific settings |
| `config/runtime.exs` | Runtime/env vars | Production deployments (reads env vars) |
| `config/test.exs` | Test overrides | Test-specific settings |

**For most users:**
- **Development:** Edit `config/dev.exs` or just use defaults
- **Production:** Set environment variables (see below) - `runtime.exs` reads them automatically

### Quick Start (Development)

The defaults work out of the box. Just run:

```bash
mix deps.get
mix ecto.create && mix ecto.migrate
iex -S mix
```

Tracker runs on `http://localhost:8080`. Admin API has no authentication in dev mode.

### Quick Start (Production)

Set these environment variables:

```bash
# Required
ADMIN_TOKEN=your_secure_random_token

# Optional - ports
HTTP_PORT=8080
UDP_PORT=8081

# Optional - HTTPS
HTTPS_PORT=443
TLS_CERT_PATH=/path/to/cert.pem
TLS_KEY_PATH=/path/to/key.pem

# Optional - PostgreSQL (default is SQLite)
DATABASE_URL=postgres://user:pass@host:5432/b1tpoti0n
# OR individual vars:
DATABASE_ADAPTER=postgresql
PG_HOST=localhost
PG_DATABASE=b1tpoti0n
PG_USER=postgres
PG_PASSWORD=secret
```

Then build and run:

```bash
MIX_ENV=prod mix release
_build/prod/rel/b1tpoti0n/bin/b1tpoti0n start
```

### All Configuration Options

Edit `config/config.exs` to change defaults. All options with their defaults:

```elixir
config :b1tpoti0n,
  # --- Network ---
  http_port: 8081,                    # HTTP port (nil to disable)
  https_port: nil,                    # HTTPS port (nil to disable)
  https_certfile: nil,                # Path to TLS certificate
  https_keyfile: nil,                 # Path to TLS private key
  https_only: false,                  # Disable HTTP when HTTPS enabled
  udp_port: nil,                      # UDP tracker port (nil to disable, BEP 15)
  udp_connection_timeout: 120,        # UDP connection ID validity (seconds)

  # --- Announce ---
  announce_interval: 1800,            # Interval returned to clients (seconds)
  announce_jitter: 0.1,               # Jitter factor (0.0-1.0, prevents thundering herd)
  enforce_announce_key: false,        # Require tracker-issued announce key (some clients incompatible)

  # --- Access Control ---
  enforce_torrent_whitelist: false,   # Require torrents to be pre-registered
  admin_token: nil,                   # Admin API token (nil = disabled)
  cors_origins: [],                   # CORS: [], "*", "https://example.com", or list
  trust_x_forwarded_for: false,       # Trust X-Forwarded-For header (only behind trusted proxy)
  admin_api_ip_whitelist: [],         # IPs allowed to access admin API (empty = all)

  # --- Rate Limiting ---
  rate_limiting_enabled: true,
  rate_limits: [
    announce: {30, :per_minute},      # 30 announces per minute per IP
    scrape: {10, :per_minute},        # 10 scrapes per minute per IP
    admin_api: {100, :per_minute}     # 100 admin requests per minute per IP
  ],
  rate_limit_whitelist: ["127.0.0.1", "::1"],  # IPs exempt from rate limiting

  # --- Ratio Enforcement ---
  min_ratio: 0.3,                     # Global minimum ratio
  ratio_grace_bytes: 5_000_000_000,   # 5GB downloaded before ratio enforced

  # --- Hit-and-Run Detection ---
  # Set to nil to disable HnR
  hnr: [
    min_seedtime: 72 * 3600,          # 72 hours minimum seed time (seconds)
    grace_period_days: 14,            # Days after completion to meet requirements
    max_warnings: 3                   # Warnings before leeching disabled
  ],

  # --- Bonus Points ---
  # Set to [] to disable bonus points
  bonus_points: [
    base_points: 1.0,                 # Points per hour per torrent seeded
    conversion_rate: 1_000_000_000    # Bytes per point when redeeming (1GB)
  ],

  # --- Peer Storage ---
  peer_storage: :memory,              # :memory (ETS) or :redis

  # --- Redis (for clustering or redis peer storage) ---
  redis: [
    enabled: false,
    url: "redis://localhost:6379"
  ],

  # --- Peer Verification (test if peers accept connections) ---
  peer_verification: [
    enabled: false,                   # Enable connection testing
    connect_timeout: 3_000,           # TCP timeout in ms
    cache_ttl: 3600,                  # Cache results for 1 hour
    max_concurrent: 50                # Max concurrent verification attempts
  ],

  # --- Clustering (multi-node) ---
  cluster: [
    enabled: true,                    # Enable Horde distributed supervision
    strategy: Cluster.Strategy.Gossip,
    config: [
      port: 45892,
      if_addr: "0.0.0.0",
      multicast_addr: "230.1.1.251",
      multicast_ttl: 1
    ]
  ],

  # --- Stats Endpoint Protection ---
  stats_endpoint: [
    enabled: true,                    # Set to false to disable /stats
    require_auth: false,              # Require admin token
    ip_whitelist: ["127.0.0.1", "::1"] # IPs allowed (empty = all if no auth)
  ],

  # --- Metrics Endpoint Protection ---
  metrics_endpoint: [
    enabled: true,                    # Set to false to disable /metrics
    require_auth: false,              # Require admin token
    ip_whitelist: ["127.0.0.1", "::1"] # IPs allowed (empty = all if no auth)
  ]
```

### Database Configuration

**SQLite (default)** - Simple, zero-config, good for small/medium sites:

```elixir
# In config/config.exs (already the default)
config :b1tpoti0n, B1tpoti0n.Persistence.Repo,
  adapter: Ecto.Adapters.SQLite3
```

**PostgreSQL** - For high-traffic or clustered deployments:

```elixir
# In config/config.exs, change adapter:
config :b1tpoti0n, B1tpoti0n.Persistence.Repo,
  adapter: Ecto.Adapters.Postgres
```

Then set connection via environment variables (runtime.exs handles this):

```bash
# Option 1: URL
DATABASE_URL=postgres://user:pass@host:5432/b1tpoti0n

# Option 2: Individual vars
DATABASE_ADAPTER=postgresql
PG_HOST=localhost
PG_DATABASE=b1tpoti0n
PG_USER=postgres
PG_PASSWORD=secret
```

### Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | 8080 | HTTP listener port |
| `HTTPS_PORT` | - | HTTPS listener port (enables HTTPS with TLS 1.2+) |
| `TLS_CERT_PATH` | - | Path to TLS certificate |
| `TLS_KEY_PATH` | - | Path to TLS private key |
| `HTTPS_ONLY` | false | Disable HTTP when HTTPS enabled |
| `UDP_PORT` | - | UDP tracker port (enables UDP, no auth support) |
| `UDP_CONNECTION_TIMEOUT` | 120 | UDP connection ID validity (seconds) |
| `ADMIN_TOKEN` | - | Admin API authentication token |
| `ADMIN_API_IP_WHITELIST` | - | Comma-separated IPs allowed to access admin API |
| `CORS_ORIGINS` | - | CORS origins (comma-separated, "*", or empty for none) |
| `DATABASE_URL` | - | PostgreSQL connection URL |
| `DATABASE_ADAPTER` | sqlite | `sqlite` or `postgresql` |
| `DATABASE_PATH` | /var/lib/b1tpoti0n/tracker.db | SQLite database path |
| `PG_HOST` | localhost | PostgreSQL host |
| `PG_PORT` | 5432 | PostgreSQL port |
| `PG_DATABASE` | b1tpoti0n | PostgreSQL database name |
| `PG_USER` | postgres | PostgreSQL username |
| `PG_PASSWORD` | - | PostgreSQL password |
| `POOL_SIZE` | 10/20 | Database connection pool size |
| `REDIS_URL` | redis://localhost:6379 | Redis connection URL |
| `CLUSTER_ENABLED` | false | Enable Horde clustering |

---

## Architecture

### Supervision Tree

```
Application
├── Repo (Ecto SQLite/PostgreSQL)
├── Store.Manager (ETS tables)
├── RateLimiter (Token bucket)
├── Metrics (Telemetry)
├── WebSocket.Registry (Real-time clients)
├── PeerVerifier (Connection testing)
├── [ClusterSupervisor] (If clustering enabled)
├── [DistributedRegistry] (If clustering - Horde)
├── [DistributedSupervisor] (If clustering - Horde)
├── Registry (Swarm workers - local mode)
├── Swarm.Supervisor (DynamicSupervisor)
├── [Store.RedisCache] (If Redis enabled)
├── Stats.Buffer (Buffered writes)
├── Stats.Collector (Periodic flush)
├── Hnr.Detector (HnR checks)
├── Bonus.Calculator (Points calculation)
├── Bandit (HTTP server)
├── [Bandit] (HTTPS server - if configured)
└── [UdpServer] (If UDP port configured)
```

### Data Flow

1. **Request arrives** (HTTP or UDP)
2. **Rate limit check** (token bucket per IP)
3. **Ban check** (ETS lookup)
4. **Passkey validation** (ETS lookup, cached from DB)
5. **Client whitelist check** (ETS lookup)
6. **Torrent lookup** (DB or ETS cache)
7. **Swarm worker** processes peer data
8. **Stats buffered** in Stats.Buffer
9. **Periodic flush** writes to DB

### ETS Tables

| Table | Purpose |
|-------|---------|
| `b1tpoti0n_passkeys` | passkey -> user_id mapping |
| `b1tpoti0n_whitelist` | client prefix whitelist |
| `b1tpoti0n_banned_ips` | IP ban list |
| `b1tpoti0n_rate_limits` | rate limit sliding window |
| `b1tpoti0n_metrics` | counters and histograms |

### Swarm Workers

Each active torrent has a dedicated GenServer (`Swarm.Worker`) managing:
- Peer list (seeders/leechers)
- Peer expiration
- Peer selection for responses

Workers are started on first announce and terminated after inactivity.

---

## Tracker Protocol

### HTTP Announce

```
GET /:passkey/announce?info_hash=...&peer_id=...&port=...&uploaded=...&downloaded=...&left=...&event=...
```

**Parameters:**
| Parameter | Required | Description |
|-----------|----------|-------------|
| info_hash | Yes | 20-byte torrent hash (URL-encoded) |
| peer_id | Yes | 20-byte peer ID (URL-encoded) |
| port | Yes | Listening port |
| uploaded | Yes | Total bytes uploaded |
| downloaded | Yes | Total bytes downloaded |
| left | Yes | Bytes remaining |
| event | No | started, stopped, completed, or empty |
| compact | No | 1 for compact response |
| numwant | No | Number of peers wanted (default 50) |
| key | No | Tracker key for session tracking |

**Response (Bencoded):**
```
d8:completei10e10:incompletei5e8:intervali1800e5:peers6:...e
```

### HTTP Scrape

```
GET /:passkey/scrape?info_hash=...
```

Multiple info_hash parameters supported.

**Response:**
```
d5:filesd20:<info_hash>d8:completei10e10:incompletei5e10:downloadedi100eeee
```

### UDP Protocol

Implements BEP 15. Connect -> Announce/Scrape flow.

**Port:** Configured via `udp_port` (disabled by default, set to enable)

**Actions:**
- 0: Connect
- 1: Announce
- 2: Scrape
- 3: Error

> **Private Tracker Limitation:** The UDP protocol (BEP 15) does not support passkey authentication. This is a protocol limitation; there's no standard way to pass authentication credentials via UDP. User upload/download stats are **not tracked** for UDP announces.
>
> Most private trackers (Gazelle/Ocelot, etc.) use HTTP only for this reason. Only enable UDP if running a public tracker or hybrid setup where stats tracking isn't required for UDP clients.

---

## Admin API

Base URL: `/admin`

Authentication: `X-Admin-Token` header (if `admin_token` configured)

### Stats

```
GET /admin/stats                 # Tracker statistics
```

### Users

```
GET    /admin/users              # List all users
GET    /admin/users/search?q=xxx # Search users by passkey
GET    /admin/users/passkey/:pk  # Get user by exact passkey
GET    /admin/users/:id          # Get user by ID
GET    /admin/users/:id/peers    # Get user's currently active peers (seeding/leeching)
POST   /admin/users              # Create user (optional: {"passkey": "..."})
DELETE /admin/users/:id          # Delete user
PUT    /admin/users/:id/stats    # Update uploaded/downloaded
PUT    /admin/users/:id/leech    # Set can_leech ({"can_leech": true/false})
POST   /admin/users/:id/reset    # Reset passkey
POST   /admin/users/:id/warnings/clear  # Clear HnR warnings
```

### Torrents

```
GET    /admin/torrents              # List torrents
GET    /admin/torrents/:id          # Get torrent (by ID or info_hash)
POST   /admin/torrents              # Register torrent ({"info_hash": "hex"})
DELETE /admin/torrents/:id          # Delete torrent
PUT    /admin/torrents/:id/stats    # Update stats
```

### Freeleech & Multipliers

```
GET    /admin/freeleech                  # List freeleech torrents
POST   /admin/torrents/:id/freeleech     # Enable freeleech (optional: {"duration": seconds})
DELETE /admin/torrents/:id/freeleech     # Disable freeleech
PUT    /admin/torrents/:id/multipliers   # Set multipliers
```

### Whitelist

```
GET    /admin/whitelist          # List whitelisted clients
POST   /admin/whitelist          # Add client ({"prefix": "-TR", "name": "Transmission"})
DELETE /admin/whitelist/:prefix  # Remove client
```

### IP Bans

```
GET    /admin/bans               # List all bans
GET    /admin/bans/active        # List active (non-expired) bans
GET    /admin/bans/:ip           # Get ban details
POST   /admin/bans               # Ban IP ({"ip": "...", "reason": "...", "duration": seconds})
PUT    /admin/bans/:ip           # Update ban
DELETE /admin/bans/:ip           # Unban IP
POST   /admin/bans/cleanup       # Remove expired bans
```

### Rate Limits

```
GET    /admin/ratelimits         # Rate limiter stats
GET    /admin/ratelimits/:ip     # Check IP state
DELETE /admin/ratelimits/:ip     # Reset IP limits
```

### Snatches

```
GET    /admin/snatches/:id           # Get snatch by ID
GET    /admin/users/:id/snatches     # List user's snatches
GET    /admin/torrents/:id/snatches  # List torrent's snatches
PUT    /admin/snatches/:id           # Update snatch (seedtime, hnr)
DELETE /admin/snatches/:id           # Delete snatch
DELETE /admin/snatches/:id/hnr       # Clear HnR flag on snatch
```

### Hit-and-Run

```
GET    /admin/hnr                # List all HnR violations
POST   /admin/hnr/check          # Trigger HnR check
```

### Bonus Points

```
GET    /admin/bonus/stats        # Calculator stats
POST   /admin/bonus/calculate    # Trigger calculation
GET    /admin/users/:id/points   # Get user's points
POST   /admin/users/:id/points   # Add points ({"points": number})
DELETE /admin/users/:id/points   # Remove points ({"points": number})
POST   /admin/users/:id/redeem   # Redeem for upload ({"points": number})
```

### System

```
POST   /admin/stats/flush        # Flush stats buffer to DB
GET    /admin/swarms             # List active swarm workers
GET    /admin/verification/stats # Peer verification stats
DELETE /admin/verification/cache # Clear verification cache
```

### WebSocket

```
GET /ws?token=<admin_token>
```

Real-time stats updates via WebSocket connection.

---

## Deployment

### Production Environment Variables

```bash
# Required
ADMIN_TOKEN=your_secure_token

# Network
HTTP_PORT=80
HTTPS_PORT=443
TLS_CERT_PATH=/etc/ssl/certs/tracker.crt
TLS_KEY_PATH=/etc/ssl/private/tracker.key
UDP_PORT=6969

# Database (SQLite)
DATABASE_PATH=/var/lib/b1tpoti0n/tracker.db

# Database (PostgreSQL - alternative)
# DATABASE_URL=postgres://user:pass@localhost:5432/b1tpoti0n

# Redis (if clustering or redis peer storage)
# REDIS_URL=redis://localhost:6379
```

### Release Build

```bash
MIX_ENV=prod mix release
_build/prod/rel/b1tpoti0n/bin/b1tpoti0n start
```

### Systemd Service

```ini
[Unit]
Description=b1tpoti0n BitTorrent Tracker
After=network.target

[Service]
Type=simple
User=tracker
WorkingDirectory=/opt/b1tpoti0n
ExecStart=/opt/b1tpoti0n/_build/prod/rel/b1tpoti0n/bin/b1tpoti0n start
ExecStop=/opt/b1tpoti0n/_build/prod/rel/b1tpoti0n/bin/b1tpoti0n stop
Restart=on-failure
RestartSec=5
Environment=DATABASE_PATH=/var/lib/b1tpoti0n/tracker.db
Environment=ADMIN_TOKEN=your_secure_token_here

[Install]
WantedBy=multi-user.target
```

### Docker

```dockerfile
FROM elixir:1.15-alpine AS build

RUN apk add --no-cache build-base

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
RUN mix release

FROM alpine:3.18
RUN apk add --no-cache libstdc++ openssl ncurses-libs sqlite-libs

WORKDIR /app
COPY --from=build /app/_build/prod/rel/b1tpoti0n ./

ENV DATABASE_PATH=/data/tracker.db
VOLUME /data

EXPOSE 8080 8081/udp

CMD ["bin/b1tpoti0n", "start"]
```

### TLS Security

When HTTPS is enabled, b1tpoti0n automatically enforces strong TLS settings:

- **TLS 1.2 and TLS 1.3 only** - Older versions (TLS 1.0, 1.1) are disabled
- **Forward secrecy** - Only ECDHE key exchange ciphers are allowed
- **Server cipher preference** - Server chooses the cipher, not the client
- **Session tickets disabled** - Prevents session resumption attacks

No configuration needed - these settings are applied automatically when you set `https_port`.

### Reverse Proxy (nginx)

```nginx
upstream tracker {
    server 127.0.0.1:8080;
}

server {
    listen 80;
    server_name tracker.example.com;

    location / {
        proxy_pass http://tracker;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
    }

    location /ws {
        proxy_pass http://tracker;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Monitoring

Prometheus metrics available at `GET /metrics` (can be protected via `metrics_endpoint` config).

Key metrics:
- `tracker_announces_total` - Total announce requests
- `tracker_announces_by_event` - Announces by event type (started, completed, stopped, update)
- `tracker_scrapes_total` - Total scrape requests
- `tracker_errors_total` - Total errors
- `tracker_errors_by_type` - Errors by type
- `tracker_announce_duration_milliseconds` - Announce latency (summary)
- `tracker_scrape_duration_milliseconds` - Scrape latency (summary)
- `tracker_users_total` - Registered users (gauge)
- `tracker_torrents_total` - Registered torrents (gauge)
- `tracker_swarms_active` - Active swarm workers (gauge)
- `tracker_peers_active` - Active peers in memory (gauge)
- `tracker_passkeys_cached` - Cached passkeys (gauge)
- `tracker_banned_ips` - Banned IPs (gauge)

### Multi-Node Deployment

For high-availability and horizontal scaling, run multiple tracker nodes.

#### Requirements

| Component | Purpose |
|-----------|---------|
| PostgreSQL | Shared database (SQLite is single-node only) |
| Redis | Shared peer storage and cache |
| Load balancer | Distribute HTTP/UDP traffic |

#### Configuration

Create `config/prod.exs`:

```elixir
import Config

# PostgreSQL for shared database
config :b1tpoti0n, B1tpoti0n.Persistence.Repo,
  adapter: Ecto.Adapters.Postgres

config :b1tpoti0n,
  # Redis peer storage (required for multi-node)
  peer_storage: :redis,

  # Redis connection
  redis: [
    enabled: true,
    url: System.get_env("REDIS_URL") || "redis://localhost:6379"
  ],

  # Enable clustering
  cluster: [
    enabled: true
  ]

# Node discovery strategy
config :libcluster,
  topologies: [
    tracker: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"node1@host1", :"node2@host2"]]
    ]
  ]
```

#### Docker Compose Example

```yaml
version: "3.8"

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: b1tpoti0n
      POSTGRES_USER: tracker
      POSTGRES_PASSWORD: secret
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data

  tracker1:
    build: .
    environment:
      DATABASE_URL: postgres://tracker:secret@postgres:5432/b1tpoti0n
      REDIS_URL: redis://redis:6379
      RELEASE_NODE: tracker@tracker1
      RELEASE_COOKIE: secret_cookie
      HTTP_PORT: 8080
      UDP_PORT: 8081
      ADMIN_TOKEN: your_admin_token
    ports:
      - "8080:8080"
      - "8081:8081/udp"
    depends_on:
      - postgres
      - redis

  tracker2:
    build: .
    environment:
      DATABASE_URL: postgres://tracker:secret@postgres:5432/b1tpoti0n
      REDIS_URL: redis://redis:6379
      RELEASE_NODE: tracker@tracker2
      RELEASE_COOKIE: secret_cookie
      HTTP_PORT: 8080
      UDP_PORT: 8081
      ADMIN_TOKEN: your_admin_token
    ports:
      - "8082:8080"
      - "8083:8081/udp"
    depends_on:
      - postgres
      - redis

volumes:
  postgres_data:
  redis_data:
```

#### Kubernetes Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: b1tpoti0n
spec:
  replicas: 3
  selector:
    matchLabels:
      app: b1tpoti0n
  template:
    metadata:
      labels:
        app: b1tpoti0n
    spec:
      containers:
      - name: tracker
        image: b1tpoti0n:latest
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: tracker-secrets
              key: database-url
        - name: REDIS_URL
          value: redis://redis-master:6379
        - name: RELEASE_COOKIE
          valueFrom:
            secretKeyRef:
              name: tracker-secrets
              key: erlang-cookie
        - name: ADMIN_TOKEN
          valueFrom:
            secretKeyRef:
              name: tracker-secrets
              key: admin-token
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 8081
          protocol: UDP
          name: udp
---
apiVersion: v1
kind: Service
metadata:
  name: b1tpoti0n
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
    name: http
  - port: 6969
    targetPort: 8081
    protocol: UDP
    name: udp
  selector:
    app: b1tpoti0n
```

Use `Cluster.Strategy.Kubernetes` for automatic node discovery:

```elixir
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        kubernetes_selector: "app=b1tpoti0n",
        kubernetes_node_basename: "b1tpoti0n"
      ]
    ]
  ]
```

#### Verify Clustering

Connect to a node and check cluster status:

```elixir
# List connected nodes
Node.list()

# Check Horde cluster members
Horde.Cluster.members(B1tpoti0n.Swarm.DistributedSupervisor)
```

#### Load Balancing

For HTTP: Any load balancer (nginx, HAProxy, cloud LB) works.

For UDP: Use IP hash or round-robin. UDP announces from the same client should ideally hit the same node, but with Redis peer storage this is not strictly required.

---

## Admin UI

A standalone admin interface is included in the `docs/` directory.
You may want to implement your own.

**[Live Demo](https://gmonarque.github.io/b1tpoti0n/)** — UI preview with mock data
