# 11 Requirements

## Host

| Item | Requirement |
|---|---|
| CPU architecture | **x86_64 / amd64 only.** The official AceStream Linux engine is a closed-source x86_64 binary; ARM hosts (Raspberry Pi, Apple Silicon) are not supported |
| OS | Linux with Docker Engine and Docker Compose v2 |
| Kernel | `/dev/net/tun` available (granted to gluetun via `devices:`); `NET_ADMIN` capability (granted in `docker-compose.yml`) |
| Ports | Two free TCP ports on the host, by default **6878** (engine HTTP API) and **8080** (playlist server) |
| Disk | ~1 GB for images plus the engine cache (`ACESTREAM_CACHE_LIMIT_GB`, default 5 GB) and the Kubo repository |
| Network | Outbound internet access; LAN or Tailscale clients able to reach the published host ports |

Docker Desktop on Linux works as long as the host is x86_64. On other
platforms the amd64 image would run emulated and is untested.

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

The `acestream` image is published to GHCR. The package is **private by
default**, so either:

- make it public (GitHub → your profile → Packages → miniace → Package
  settings → Change visibility), or
- run `docker login ghcr.io` with a token that has `read:packages` before
  `docker compose pull`.

Building locally (`docker compose up -d --build`) avoids GHCR entirely.

## Legal

AceStream is closed-source software distributed by its authors as an
official tarball under its own user agreement. The Dockerfile pins the
tarball by SHA256 but does not redistribute it.
