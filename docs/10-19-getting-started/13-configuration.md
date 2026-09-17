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
| `ACESTREAM_CACHE_LIMIT_GB` | `5` | Engine disk cache size in GB; `0` disables the cache. |
| `PORT_WATCH_INTERVAL_S` | `45` | How often the watcher checks Gluetun for a rotated forwarded port. |
| `TZ` | `Europe/Madrid` | Timezone of the containers (logs). |
| `DOCKER_SUBNET` | `172.30.0.0/24` | Compose network subnet. Must not overlap the VPN tunnel range. |

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
- **`data/sources.json`** is the only runtime config file; its format is
  documented in [21 Playlists](../20-29-operation/21-playlists.md).
