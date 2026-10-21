# 31 Architecture

```text
IPTV client (TiviMate / VLC / Jellyfin)
   │  stream:    http://<HOST>:6878/ace/getstream?id=<hash>
   │  playlists: http://<HOST>:8080/{<source>,all}.m3u
   ▼
[gluetun] ──netns──► [acestream]
                         │  outpace P2P bound to the port announced by ProtonVPN
                         ▼
                      [kubo] :48080 (IPNS resolution, Docker network only)
```

## Containers

| Service | Image | Responsibility |
|---|---|---|
| gluetun | `qmcgaw/gluetun` (official, digest-pinned) | WireGuard tunnel to ProtonVPN, NAT-PMP port forwarding, control server on `:8001`, publishes `6878` / `8080`, firewall |
| acestream | `ghcr.io/biquinisdonrodrigo/miniace:latest` | outpace engine, port supervisor, IPNS→M3U sync, playlist HTTP server |
| kubo | `ipfs/kubo:v0.43.0` (official) | Local IPFS node; gateway exposed on `0.0.0.0:48080` |

## Key design decisions

- **The engine shares Gluetun's network namespace**
  (`network_mode: service:gluetun`), so it egresses through the VPN and can
  bind the forwarded port directly. Gluetun publishes the ports.
- **The engine never falls back to a static port.** It binds only the port
  ProtonVPN announces; while no port exists it waits. See
  [32 P2P port forwarding](32-p2p-port-forwarding.md).
- **Only the engine is tunneled.** Kubo and the playlist server talk
  directly, so IPFS traffic does not go through ProtonVPN.
- **Only the acestream image is custom.** Gluetun and Kubo run untouched
  official images; the single exception is a one-line init script that
  moves the Kubo gateway from localhost to `0.0.0.0:48080` so the
  acestream container can reach it.
- **The image is multi-arch.** The same tag is published for `linux/amd64`,
  `linux/arm64` and `linux/arm/v7`; the engine binary comes from the official
  outpace image and is identical across architectures.

## Startup order

Compose starts Gluetun first (`depends_on`), but `depends_on` only waits
for the container to exist, not for the VPN to be ready. The stack is
designed for that:

- the engine supervisor polls Gluetun until a forwarded port appears;
- the sync loop retries failed sources every `RETRY_INTERVAL` (60 s) until
  the next full cycle.

## Inside the acestream container

`entrypoint.sh` starts three things:

| Process | Role |
|---|---|
| `outpace.sh` → `start_engine` | Supervises outpace: resolves the forwarded port, spawns `outpace serve`, restarts on crash or rotation |
| `outpace.sh` → `port_watch_loop` | Polls Gluetun every `PORT_WATCH_INTERVAL_S` and stops the engine when the port rotates |
| `sync.py` | Foreground process: playlist sync loop + HTTP server; when it exits, the container shuts down |

The supervisor probes `GET /healthz` on loopback to decide whether the
engine is alive. It does not depend on the outpace PID, so a crashed daemon
is detected even if a shell wrapper is still present.
