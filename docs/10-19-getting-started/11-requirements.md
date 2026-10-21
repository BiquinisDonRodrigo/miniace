# 11 Requirements

## Host

| Item | Requirement |
|---|---|
| CPU architecture | **x86_64 / amd64, arm64 / aarch64 or armv7 (armhf).** The image is built for `linux/amd64`, `linux/arm64` and `linux/arm/v7`; the engine is [outpace](https://github.com/jamezrin/outpace) |
| OS | Linux with Docker Engine and Docker Compose v2 |
| Kernel | `/dev/net/tun` available (granted to gluetun via `devices:`); `NET_ADMIN` capability (granted in `docker-compose.yml`) |
| Ports | Two free TCP ports on the host, by default **6878** (engine HTTP API) and **8080** (playlist server) |
| Disk | Image space plus the outpace cache/data under `data/acestream/` and the Kubo repository |
| Network | Outbound internet access; LAN or Tailscale clients able to reach the published host ports |

Docker Desktop on Linux and macOS works on both amd64 and arm64 hosts. On
32-bit ARM, outpace is supported but has less headroom for concurrent
streams; see [13 Configuration](13-configuration.md#outpace-tuning).

outpace does not embed the Android libraries that make some third-party ARM
AceStream images fail on 16 KiB-page kernels, but 16 KiB-page support is not
formally qualified upstream. If you run a kernel built for 16 KiB pages,
verify playback before relying on it.

## Accounts and credentials

1. **ProtonVPN paid plan** (Plus or Unlimited). Port forwarding is not
   available on the free plan.
2. A **WireGuard configuration** generated at
   <https://account.proton.me/vpn/WireGuard> with the
   **"NAT-PMP (Port Forwarding)"** option enabled. Copy the `PrivateKey`
   value into `WG_PRIVATE_KEY`.
3. A VPN server that supports port forwarding. miniace sets
   `PORT_FORWARD_ONLY=on`, so Gluetun only picks capable servers.

Without a forwarded port the engine never starts, by design. See
[32 P2P port forwarding](../30-39-architecture/32-p2p-port-forwarding.md).

## Playlist sources

`data/sources.json` must exist with at least one usable source; see
[21 Playlists](../20-29-operation/21-playlists.md). IPNS origins resolve
through the bundled Kubo node, with public gateways as fallback.

## Image registry access

The `acestream` image is published publicly to GHCR as
`ghcr.io/biquinisdonrodrigo/miniace`: `docker compose up -d` pulls it with
no authentication.

Building locally (`docker compose up -d --build`) avoids GHCR entirely.

## Legal

miniace uses [outpace](https://github.com/jamezrin/outpace), an independent
open-source Rust implementation of the public AceStream live path, licensed
under **AGPL-3.0-or-later**. The image copies the outpace binary from the
official multi-arch image pinned by digest; the corresponding source is
published by the outpace project. It is not the official AceStream engine.

AceStream is a trademark of its respective owners. miniace is not affiliated
with, endorsed by, or connected to the AceStream developers or to the
outpace maintainers. The operator remains responsible for complying with
the licences and terms of every component and service they use.
