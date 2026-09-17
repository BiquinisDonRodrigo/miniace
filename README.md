# miniace

[![Build acestream image](https://github.com/BiquinisDonRodrigo/miniace/actions/workflows/docker.yml/badge.svg)](https://github.com/BiquinisDonRodrigo/miniace/actions/workflows/docker.yml)

**Full documentation:** [docs/intro.md](docs/intro.md) — requirements,
installation, configuration, playlists, architecture and troubleshooting.

Dockerized [AceStream](https://www.acestream.org/) engine behind a
ProtonVPN WireGuard tunnel with **dynamic P2P port forwarding**, plus
**IPFS/IPNS M3U playlist** support. Three containers, one custom image:

| Service  | Image                | Role |
|----------|----------------------|------|
| gluetun  | `qmcgaw/gluetun:v3.41.3` (official) | VPN tunnel, NAT-PMP port forwarding, published ports |
| acestream | `ghcr.io/biquinisdonrodrigo/miniace:latest` (built by CI) | AceStream 3.2.11 engine + port supervisor + IPNS→M3U sync + playlist HTTP server |
| kubo     | `ipfs/kubo:v0.43.0` (official)     | Local IPFS node resolving the `ipns://` playlists |

```
IPTV client (TiviMate / VLC / Jellyfin)
   │  stream:    http://<HOST>:6878/ace/getstream?id=<infohash>
   │  playlists: http://<HOST>:8080/{<source>,all}.m3u
   ▼
[gluetun] ──netns──► [acestream]
                        │  engine P2P bound to the port announced by ProtonVPN
                        ▼
                     [kubo] :48080 (IPNS resolution, Docker network only)
```

## Hard requirement: the announced P2P port

The engine **only** binds the port ProtonVPN announces via NAT-PMP. It never
falls back to a static port (8621): while no forwarded port exists the engine
waits, and when ProtonVPN rotates it (every reconnect) the engine is restarted
and rebound automatically. This matters because binding any other port makes
inbound P2P connectivity silently impossible.

Resolution order for the forwarded port:

1. Gluetun control API `GET /v1/portforward` (loopback `:8001` of the shared netns)
2. Legacy route `/v1/port_forwarded`
3. `/tmp/gluetun/forwarded_port` status file (shared volume)

The engine is started with the flags documented by the engine itself
(`Plugin/BackgroundProcess.py`): `--http-port=<api>` for the HTTP API and
`--port=<p2p>` for the P2P session port. Verify at any time:

```sh
docker compose logs gluetun | grep -i "forwarded port"      # announced port N
docker compose logs acestream | grep "P2P on forwarded"     # engine bound to N
docker compose exec gluetun ss -lntup | grep -E "6878|<N>"  # both listening
```

## Requirements

- Docker + Docker Compose v2, x86_64 host (the official Linux engine is amd64 only)
- ProtonVPN **paid plan** (Plus/Unlimited) — port forwarding is not available on free
- A WireGuard configuration generated at
  [account.proton.me/vpn/WireGuard](https://account.proton.me/vpn/WireGuard)
  with **"NAT-PMP (Port Forwarding)"** enabled

## Quick start

```sh
cp .env.example .env
# edit .env: WG_PRIVATE_KEY (the PrivateKey from the ProtonVPN config)
docker compose pull && docker compose up -d    # prebuilt image from GHCR
# or: docker compose up -d --build             # build the image locally
```

## Build / CI

`.github/workflows/docker.yml` builds `images/acestream` and publishes it to
[GHCR](https://github.com/BiquinisDonRodrigo/miniace/pkgs/container/miniace):

- push to `main` → `latest` + `sha-<short>`
- tag `vX.Y.Z` → `X.Y.Z` and `X.Y`
- pull requests → build only (no push)

Only `linux/amd64` is built (the official engine is x86_64 only). The GHCR
package is **private** by default: either make it public (GitHub → Packages →
miniace → Package settings) or authenticate with `docker login ghcr.io` before
`docker compose pull`.

## Playlists

Sources are declared in `data/sources.json` (re-read on every sync cycle, so
edits apply without restarting):

```json
[
  {"name": "example", "origin": "ipns://<key>/playlist.m3u"},
  {"name": "iptv", "origin": "ipns://<key>/channels.m3u"}
]
```

Every AceStream entry (bare infohash, `acestream://<hash>` or
`http://…?id=<hash>`) is rewritten **per request** to
`http://<request-host>:$ACESTREAM_HTTP_PORT/ace/getstream?id=<hash>`, where
`<request-host>` is the host you used to fetch the playlist; all other URLs are
preserved. The same playlist therefore works from the LAN and from Tailscale at
once: fetched via `http://192.168.1.100:8080/all.m3u`, entries point to
`192.168.1.100:6878`; fetched via `http://100.64.x.x:8080/all.m3u`, they point
to `100.64.x.x:6878`. Output lands in `data/playlists/` (`<name>.m3u` per source
plus a merged `all.m3u`) and is served at `http://<HOST>:8080/`. Files on disk
keep a `__MINIACE_HOST__` placeholder that the HTTP server substitutes.

IPNS resolution goes through the local Kubo gateway
(`http://kubo:48080`) and falls back to public gateways
(`IPFS_FALLBACK_GATEWAYS`) when local resolution is slow or fails. The first
IPNS resolution on a fresh Kubo node can take a few minutes.

## Configuration

See `.env.example`. Highlights:

| Variable | Default | Description |
|---|---|---|
| `WG_PRIVATE_KEY` | — | ProtonVPN WireGuard private key (required) |
| `PROTON_COUNTRIES` | `Netherlands` | VPN server countries |
| `ACESTREAM_HTTP_PORT` | `6878` | Engine HTTP API port (host + container) |
| `PLAYLISTS_PORT` | `8080` | Playlist HTTP server port (host + container) |
| `SYNC_INTERVAL` | `3600` | Seconds between playlist refreshes |
| `ACESTREAM_CACHE_LIMIT_GB` | `5` | Engine disk cache in GB (`0` disables) |
| `PORT_WATCH_INTERVAL_S` | `45` | How often port rotations are detected |
| `DOCKER_SUBNET` | `172.30.0.0/24` | Compose subnet; must not overlap the VPN tunnel range |

## Data layout

```
data/
├── sources.json    # playlist sources (yours)
├── playlists/      # generated .m3u files (yours, gitignored)
├── gluetun/        # forwarded-port status file (runtime)
├── ipfs/           # Kubo repository (runtime)
└── acestream/      # engine state + disk cache (runtime)
```

## How it works

- **gluetun** connects ProtonVPN over WireGuard, requests a port via NAT-PMP
  and exposes it on its control server plus the `/tmp/gluetun/forwarded_port`
  file. `FIREWALL_INPUT_PORTS` lets LAN clients reach the published 6878/8080,
  `FIREWALL_OUTBOUND_SUBNETS` lets the acestream container reach kubo.
- **acestream** shares gluetun's network namespace. Its entrypoint runs:
  - `engine.sh`: resolves the announced port, starts
    `start-engine --client-console --bind-all --http-port=6878 --port=<N>
    --log-file=… --vod-buffer=30 --state-dir=… --cache-dir=… --cache-limit=…`
    (stdout logging stays on for `docker compose logs`; the file log lives in
    the persisted state dir), supervises it by probing the
    HTTP API (the launcher daemonizes), sweeps orphan daemons, and restarts the
    engine whenever the announced port rotates.
  - `sync.py`: playlist sync + HTTP server (see above).
- **kubo** runs the official image with `IPFS_PROFILE=server`. The only
  addition is the one-line `kubo/001-gateway-port.sh` mounted into the image's
  official `/container-init.d` extension point, which binds the gateway to
  `0.0.0.0:48080` (stock kubo binds it to localhost, unreachable from other
  containers).

## Troubleshooting

- **No forwarded port** (`engine: no Gluetun forwarded port available yet`):
  ProtonVPN plan without port forwarding, WireGuard config generated without
  NAT-PMP, or a server without support (`PORT_FORWARD_ONLY=on` filters for
  capable ones). Check `docker compose logs gluetun`.
- **Playlist 404 / empty**: first IPNS resolution can take minutes on a fresh
  Kubo repo; check `docker compose logs kubo` and
  `docker compose logs acestream | grep sync`. Force a refresh with
  `docker compose restart acestream`.
- **DNS errors at first boot** (`Temporary failure in name resolution`): the
  sync starts before gluetun has its DNS/VPN ready, so the first cycle can fail
  all fetches. It retries every `RETRY_INTERVAL` (default 60 s) until at least
  one source is refreshed, so playlists appear shortly after the VPN is up.
- **kubo unreachable from acestream**: verify `FIREWALL_OUTBOUND_SUBNETS`
  matches the compose network subnet (`DOCKER_SUBNET`).
- **Streams fail from clients but work locally**: the client must reach the
  engine port (`ACESTREAM_HTTP_PORT`, default 6878) on the same host it used to
  fetch the playlist, and the engine needs inbound access to that port
  (`FIREWALL_INPUT_PORTS`).

## Notes

- Only the `acestream` image is custom; gluetun and kubo run their official
  images untouched.
- Kubo and the playlist traffic stay outside the VPN; only the engine is
  tunneled.
- AceStream is closed-source software distributed as an official tarball
  (SHA256-pinned in the Dockerfile) under its own user agreement.
