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
| `SYNC_INTERVAL` | `3600` | Seconds between playlist refreshes. |
| `IPFS_GATEWAY` | `http://kubo:48080` | Local Kubo gateway used to resolve `ipns://` / `ipfs://` origins. |
| `IPFS_FALLBACK_GATEWAYS` | `https://ipfs.filebase.io,https://ipfs.io,https://dweb.link,https://w3s.link` | Public gateways tried when the local one fails or is slow. |
| `TZ` | `Europe/Madrid` | Timezone of the containers (logs). |
| `DOCKER_SUBNET` | `172.30.0.0/24` | Compose network subnet. Must not overlap the VPN tunnel range. |

### Engine: connection and slot budgets

| Variable | Default | Description |
|---|---|---|
| `ACESTREAM_MAX_CONNECTIONS` | `2000` | Total engine connection ceiling (all streams, both directions). |
| `ACESTREAM_MAX_PEERS_LIMIT` | `500` | Adaptive peer ceiling per active stream. |
| `ACESTREAM_STARTUP_MAX_PEERS` | `100` | Peer budget at engine start (`--max-peers` and `--startup-max-peers`). |
| `ACESTREAM_STARTUP_UPLOAD_SLOTS` | `50` | Upload-slot budget at engine start. |
| `ACESTREAM_MAX_UPLOAD_SLOTS` | empty (factory 10) | Manual upload-slot ceiling; applies when `FIX_UPLOAD_SLOTS=0` and to VOD. |
| `ACESTREAM_MIN_UPLOAD_SLOTS` | empty (factory 6) | Manual upload-slot floor. |
| `ACESTREAM_FIX_UPLOAD_SLOTS` | `1` | Adaptive slot manager on (`1`, default) or fixed manual slots (`0`). |
| `ACESTREAM_MAX_TIMESHIFT_PEERS` | empty (0) | Connections reserved for timeshift (live-seek) peers. |

Budget requirement: `startup slots <= startup peers <= peer limit <= connections`.

### Engine: rate limits (Kb/s)

| Variable | Default | Description |
|---|---|---|
| `ACESTREAM_UPLOAD_LIMIT` | `0` | Upload rate limit; `0` = unlimited. |
| `ACESTREAM_DOWNLOAD_LIMIT` | `0` | Download rate limit; `0` = unlimited. |

### Engine: slot manager tuning

The CPU thresholds only apply when `ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT=1`.

| Variable | Default | Factory | Description |
|---|---|---|---|
| `ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT` | `0` | — | Apply CPU thresholds to slot changes (`0` = grow freely). |
| `ACESTREAM_SLOTS_MANAGER_MIN_SLOTS` | empty | `12` | Slot floor under CPU pressure; slots never drop below it. |
| `ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT` | empty | `20` | Total CPU % below which slots may rise. |
| `ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT` | empty | `25` | Total CPU % above which slots fall. |
| `ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT_PER_CORE` | empty | `70` | Per-core CPU % below which slots may rise. |
| `ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT_PER_CORE` | empty | `85` | Per-core CPU % above which slots fall. |
| `ACESTREAM_SLOTS_MANAGER_BASE_BITRATE` | empty | `307200` | Per-peer upload cost ceiling in bytes/s; the adaptive loop divides measured upload by `min(bitrate, this)`. |
| `ACESTREAM_WANTED_SLOTS_FACTOR` | empty | `2` | Multiplier from measured upload to wanted slots. |
| `ACESTREAM_STARTUP_SLOTS_FACTOR` | empty | `3` | Multiplier applied to past upload rates at engine start. |
| `ACESTREAM_FIX_UPLOAD_SLOTS_INTERVAL` | empty | `5` | Seconds between adaptive slot adjustments. |

### Engine: stream cache

| Variable | Default | Description |
|---|---|---|
| `ACESTREAM_CACHE_LIMIT_GB` | `5` | Disk cache budget in GB for downloaded pieces; `0` = no disk caching. |
| `ACESTREAM_LIVE_CACHE_TYPE` | `auto` | Live cache backend: `auto` = `disk` when the disk budget is above 0 GB, `memory` when it is 0; `disk`/`memory` force it. |
| `ACESTREAM_VOD_CACHE_TYPE` | `auto` | Same as above for VOD playback. |
| `ACESTREAM_LIVE_MEM_CACHE_SIZE` | empty (engine default) | Live memory-cache size in bytes. |
| `ACESTREAM_LIVE_DISK_CACHE_SIZE` | empty (engine default) | Live disk-cache size in bytes. |
| `ACESTREAM_MEMORY_CACHE_LIMIT` | empty (engine default) | RAM cache limit in bytes. |

### Engine: playback and logging

| Variable | Default | Description |
|---|---|---|
| `ACESTREAM_VOD_BUFFER` | `30` | VOD playback buffer in seconds. |
| `ACESTREAM_LOG_STDOUT_LEVEL` | `info` | Engine log level on stdout: `error`, `info`, `debug` or `any`. |
| `ACESTREAM_LOG_MAX_SIZE` | `10485760` | Rotating engine log file: maximum size in bytes (10 MB). |
| `ACESTREAM_LOG_BACKUP_COUNT` | `1` | Rotating engine log file: number of backups. |
| `ACESTREAM_VERBOSE_MODULES` | empty | Comma-separated engine modules to log verbosely (e.g. `prefs,live`). |

### Engine: extra flags and port watcher

| Variable | Default | Description |
|---|---|---|
| `ACESTREAM_EXTRA_FLAGS` | empty | Extra engine CLI flags: space-separated `--flag[=value]` tokens, appended last (the last occurrence wins). Managed options are rejected — see [Engine option surface](#engine-option-surface). |
| `PORT_WATCH_INTERVAL_S` | `10` | Seconds between checks of the Gluetun-announced forwarded port. |

## Engine option surface

Conventions shared by every engine variable:

- **Empty value = factory default**: the flag is not passed. Units are Kb/s
  for rate limits, bytes for cache sizes and seconds for timers.
- Every option maps 1:1 to a documented AceStream CLI flag
  (`ACESTREAM_SLOTS_MANAGER_BASE_BITRATE` →
  `--core-slots-manager-base-bitrate` and so on).
- **`ACESTREAM_EXTRA_FLAGS`** is the power-user passthrough for anything else
  the engine accepts. Tokens are validated against `--flag[=value]`, and
  **managed options are rejected**: connection budgets, rate limits, cache
  settings, playback buffer, ports and paths have dedicated variables —
  duplicating them here would fight the settings sync after restarts.

**Fixed by design** (no variable): `--client-console`, `--bind-all`,
`--disable-sentry`, `--log-stdout`, `--log-file`, `--http-port` (from
`ACESTREAM_HTTP_PORT`), `--port` (always the Gluetun-announced P2P port),
`--state-dir` and `--cache-dir` (internal stack paths).

## Upload-first profile

miniace explicitly requests unlimited upload (`ACESTREAM_UPLOAD_LIMIT=0`)
and adaptive upload slots (`ACESTREAM_FIX_UPLOAD_SLOTS=1`). The slot manager
increases
slots as upload demand grows, up to `ACESTREAM_MAX_PEERS_LIMIT`. Setting only
`ACESTREAM_MAX_UPLOAD_SLOTS` would not raise that adaptive ceiling.

The starting profile requests 2000 total connections, raises the adaptive
peer ceiling from 100 to 500, the startup peer budget from 50 to 100 and the
startup slot budget from 10 to 50. Actual initial slots can also depend on
the engine's rate history and concurrent
playback sessions. These are capacity budgets, not target connection counts.

`ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT=0` allows slot growth without the
engine's CPU thresholds. `1` enables its factory CPU-based control. Compose
sets both soft and hard `nofile` limits to 65536 to provide room for the
larger connection budget. The engine logs the requested profile at startup.

**Client settings must also be persisted.** The native preference default
for total connections is 1000, but the Desktop client initializes it from
player settings (500 on a fresh installation), overwriting the CLI value.
`configure_engine.py` uses the authenticated loopback settings API to apply
the connection/peer budgets, unlimited upload, adaptive slots and cache
settings. When values change, the supervisor restarts the engine once to
load them into native preferences; unchanged settings require no extra
restart. Look for `engine: client settings verified` in the logs.

Connection/slot budgets and the polling interval must be positive decimal
integers. Optional engine options accept an empty value (factory default) or
a non-negative decimal integer; cache types accept `auto`/`disk`/`memory`,
the CPU switches `0`/`1`, the log level `error`/`info`/`debug`/`any`, and the
budgets must satisfy:

```
startup upload slots <= startup peers <= peer limit <= total connections
```

Invalid settings stop the container before background services start.
Defaults apply to new variables even with an existing `.env`; values already
in `.env` override them, including an older `PORT_WATCH_INTERVAL_S=45`.

To deploy these launcher changes from a checkout:

```sh
docker compose up -d --build
```

The profile shares data during active playback. Throughput depends on peers
requesting pieces, the VPN server, available CPU and cache I/O. Compare
sustained performance using [42 Diagnostics](../40-49-troubleshooting/42-diagnostics.md#upload-throughput).

## Stream cache

The default disk cache retains pieces that can be uploaded to peers. With the
default `auto` cache types, `ACESTREAM_CACHE_LIMIT_GB=0` selects
`--live-cache-type=memory` and `--vod-cache-type=memory`; simply omitting a
cache-size flag does not disable the engine's disk cache. Both types are
supported by the pinned 3.2.11 engine and can be set explicitly (an explicit
`disk` with a 0 GB budget uses the engine's factory disk limit). The engine's
RAM cache has its own engine-managed limit; setting the disk budget to zero
does not mean zero memory use. `ACESTREAM_VOD_BUFFER` is a separate
playback-buffer setting, not a live upload tuning option.

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
