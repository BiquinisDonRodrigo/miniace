# 13 Configuration

All configuration is environment variables in `.env` (Compose reads it
automatically) plus the runtime file `data/sources.json`. `.env` is
gitignored; `.env.example` is the tracked template.

## Variables

| Variable | Default | Description |
|---|---|---|
| `WG_PRIVATE_KEY` | — | **Required.** ProtonVPN WireGuard `PrivateKey`. |
| `PROTON_COUNTRIES` | `Netherlands` | Comma-separated list of countries for server selection. |
| `ACESTREAM_HTTP_PORT` | `6878` | Host port published for the engine HTTP API. The container port stays 6878. |
| `PLAYLISTS_PORT` | `8080` | Host port published for the playlist server. The container port stays 8080. |
| `SYNC_INTERVAL` | `3600` | Seconds between playlist refreshes. Sources that fail are retried every `RETRY_INTERVAL` (60 s) until the next cycle. |
| `IPFS_GATEWAY` | `http://kubo:48080` | Local Kubo gateway used to resolve `ipns://` / `ipfs://` origins. |
| `IPFS_FALLBACK_GATEWAYS` | `https://ipfs.filebase.io` | Public gateways tried when the local one fails or is slow. ipfs.io, dweb.link and w3s.link were retired on 2026-09-21; any fallback must serve both `/ipfs/` and `/ipns/` paths. |
| `TZ` | `Europe/Madrid` | Timezone of the containers (logs). |
| `DOCKER_SUBNET` | `172.30.0.0/24` | Compose network subnet. Must not overlap the VPN tunnel range. |

## Outpace tuning

The engine is [outpace](https://github.com/jamezrin/outpace), a Rust
implementation of the public AceStream live path. All engine settings are
environment variables read at process start; changing one recreates the
engine process on the next `docker compose up -d`.

| Variable | Default | Description |
|---|---|---|
| `OUTPACE_CACHE_TYPE` | `memory` | Where retained piece data lives: `memory` or `disk`. Disk mode writes under `/acestream/outpace/cache` and wipes it on startup. |
| `OUTPACE_SEED_STORE_BYTES` | `134217728` | Hard byte ceiling **per active stream** for retained pieces (128 MiB). |
| `OUTPACE_SEED_RETENTION_SECS` | `45` | Seconds of recent pieces kept for reseeding. `0` disables the age bound and leaves only the byte ceiling. |
| `OUTPACE_MAX_INBOUND` | `64` | Maximum inbound peer connections accepted by the daemon. |
| `OUTPACE_MAX_ACTIVE_UPSTREAMS` | `4` | Active upstream peers used to follow one live stream (max 256). |
| `OUTPACE_MAX_PARALLEL_CONNECT` | `12` | Peer connect race batch size per stream (max 1024). |
| `OUTPACE_SESSION_BUFFER` | `256` | Per-client fan-out channel depth; must be at least 1. |
| `OUTPACE_PREBUFFER_BYTES` | `134217728` | Startup prebuffer byte ceiling per stream (128 MiB). Lower it on small boards running several streams. |
| `OUTPACE_ENABLE_INBOUND` | `1` | `1` accepts inbound peers and seeds them; `0` makes a pure leecher. |
| `OUTPACE_ENABLE_SEEDING` | `1` | `1` uploads pieces over outbound peer connections; `0` disables reciprocal upload. |
| `PORT_WATCH_INTERVAL_S` | `10` | Seconds between checks of the Gluetun-announced forwarded port. |

Sizes are bytes. The cache budget is per active stream, not a global volume
quota; size it against the number of streams and the RAM/disk you can
dedicate. On ARMv7, memory cache budgets are capped at roughly 512 MiB per
pool by the target's address space.

### Fixed by the stack

The supervisor sets these values and they are not meant to be overridden:

- `OUTPACE_BIND=0.0.0.0:6878` — the HTTP API port is always 6878 inside the
  container; `ACESTREAM_HTTP_PORT` only changes the published host port.
- `OUTPACE_PEER_LISTEN=0.0.0.0:<forwarded>` — always the port announced by
  ProtonVPN. There is no static fallback.
- `OUTPACE_RTMP_BIND=127.0.0.1:1935` — the optional RTMP ingest stays
  loopback-only and is not published.
- `OUTPACE_DATA_DIR=/acestream/outpace`.
- `OUTPACE_ENABLE_PORT_MAPPING=0` — Gluetun owns the NAT-PMP mapping.
- `OUTPACE_EXPERIMENTAL_ACE_COMPAT=1` — required by the generated
  `/ace/getstream` playlists. Outpace's native `/streams` API remains the
  supported surface; the compatibility routes are experimental.

## Engine behavior

- **The engine binds only the forwarded port.** The supervisor polls
  Gluetun's control API and status file, starts `outpace serve` with
  `OUTPACE_PEER_LISTEN` set to the announced port, and restarts it when the
  port rotates. While no port exists, the engine does not start.
- **No settings API.** The official engine's `/api/v1/settings` endpoint and
  the `configure_engine.py` helper no longer exist in this stack. Everything
  is configured through the `OUTPACE_*` variables above.
- **Upload-first by default.** `OUTPACE_ENABLE_INBOUND=1` and
  `OUTPACE_ENABLE_SEEDING=1` make the daemon a full P2P participant: it
  accepts peers, seeds, and announces itself to trackers and DHT. Set them
  to `0` for a pure leecher.
- **No rate limits or slot manager.** outpace does not implement the
  official engine's upload/download limits or adaptive upload-slot manager.
  Tune `OUTPACE_MAX_INBOUND`, `OUTPACE_MAX_ACTIVE_UPSTREAMS` and
  `OUTPACE_PREBUFFER_BYTES` instead.

## Stream cache

The default `memory` backend keeps retained pieces in RAM, bounded by age
(`OUTPACE_SEED_RETENTION_SECS`) and bytes (`OUTPACE_SEED_STORE_BYTES`), so
memory tracks the stream bitrate rather than filling the byte cap. Disk mode
trades RAM for capacity:

```dotenv
OUTPACE_CACHE_TYPE=disk
OUTPACE_SEED_STORE_BYTES=536870912
```

The disk cache is **ephemeral**: it is wiped on startup and per-stream
directories are removed at teardown. It is not a durable media cache. The
default cache directory is `/acestream/outpace/cache`; outpace refuses to
wipe a non-empty cache directory that lacks its `.outpace-cache` sentinel.

## Migration from the official engine

The `ACESTREAM_*` engine-tuning variables from previous miniace versions are
no longer read by the container. They can stay in `.env` without breaking
anything, but they have no effect. What changed:

| Old variable | Status |
|---|---|
| `ACESTREAM_MAX_CONNECTIONS`, `ACESTREAM_MAX_PEERS_LIMIT`, `ACESTREAM_STARTUP_MAX_PEERS`, `ACESTREAM_STARTUP_UPLOAD_SLOTS` | Removed; use `OUTPACE_MAX_INBOUND` / `OUTPACE_MAX_ACTIVE_UPSTREAMS`. |
| `ACESTREAM_MAX_UPLOAD_SLOTS`, `ACESTREAM_MIN_UPLOAD_SLOTS`, `ACESTREAM_FIX_UPLOAD_SLOTS`, `ACESTREAM_MAX_TIMESHIFT_PEERS` | Removed; outpace has no slot manager. |
| `ACESTREAM_SLOTS_MANAGER_*`, `ACESTREAM_WANTED_SLOTS_FACTOR`, `ACESTREAM_STARTUP_SLOTS_FACTOR` | Removed; outpace has no adaptive slot manager. |
| `ACESTREAM_UPLOAD_LIMIT`, `ACESTREAM_DOWNLOAD_LIMIT` | Removed; outpace has no rate limits. |
| `ACESTREAM_CACHE_LIMIT_GB`, `ACESTREAM_LIVE_CACHE_TYPE`, `ACESTREAM_VOD_CACHE_TYPE`, `ACESTREAM_LIVE_MEM_CACHE_SIZE`, `ACESTREAM_LIVE_DISK_CACHE_SIZE`, `ACESTREAM_MEMORY_CACHE_LIMIT` | Replaced by `OUTPACE_CACHE_TYPE`, `OUTPACE_SEED_STORE_BYTES` and `OUTPACE_SEED_RETENTION_SECS`. |
| `ACESTREAM_VOD_BUFFER` | Removed; outpace handles live and VOD buffering with its own defaults. |
| `ACESTREAM_LOG_STDOUT_LEVEL`, `ACESTREAM_LOG_MAX_SIZE`, `ACESTREAM_LOG_BACKUP_COUNT`, `ACESTREAM_VERBOSE_MODULES` | Removed; outpace logs to stdout and Compose rotates the container log. |
| `ACESTREAM_EXTRA_FLAGS` | Removed; outpace has no equivalent passthrough. |

The old `data/acestream/state/` and `data/acestream/cache/` directories are
not used by outpace and can be deleted after migrating. The engine identity
lives in `data/acestream/outpace/identity.seed`.

## Notes

- **Host vs container ports.** Only the host side changes with
  `ACESTREAM_HTTP_PORT` / `PLAYLISTS_PORT`; inside the shared network
  namespace the engine always listens on 6878 and the playlist server on
  8080. `PUBLIC_PORT` (passed to the sync process) tells the playlist
  rewriter which host port to embed in stream URLs; Compose derives it
  from `ACESTREAM_HTTP_PORT` automatically.
- **Apply changes** with `docker compose up -d` (recreates the affected
  containers). `sources.json` is re-read on every sync cycle and needs no
  restart.
- **`DOCKER_SUBNET`** is also passed to Gluetun as
  `FIREWALL_OUTBOUND_SUBNETS`, so the acestream container can reach Kubo.
  Keep it out of the ProtonVPN WireGuard range (10.x.x.x).
- **Advanced sync tuning.** `sync.py` also reads `RETRY_INTERVAL` (default
  60 s) and `FETCH_TIMEOUT` (default 120 s). Compose does not expose them;
  add them to the `acestream` service `environment:` if you need to.
- **`data/sources.json`** declares playlist sources; its format is documented
  in [21 Playlists](../20-29-operation/21-playlists.md).
