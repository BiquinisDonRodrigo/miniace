# 14 First run

The first boot is the slowest: Kubo initializes its repository, Gluetun
connects the VPN and asks ProtonVPN for a forwarded port, and the first
IPNS resolution can take minutes.

## What happens, in order

1. **gluetun** connects to ProtonVPN over WireGuard and requests a
   forwarded port via NAT-PMP (`VPN_PORT_FORWARDING=on`).
2. **kubo** initializes `data/ipfs/` and binds its gateway to
   `0.0.0.0:48080`.
3. **acestream** starts the playlist server immediately and waits for the
   forwarded port. The engine only starts once a port exists.
4. The first sync cycle may fail with DNS errors while the VPN comes up;
   it retries every 60 s until at least one source is fetched.

## Verification checklist

All three containers are up (the `acestream` healthcheck probes the
playlist server on `:8080`):

```sh
docker compose ps
```

Gluetun announced a port:

```sh
docker compose logs gluetun | grep -i "forwarded port"
```

The engine is bound to that same port and the playlist server is up:

```sh
docker compose logs acestream | grep -E "P2P on forwarded|playlists: serving"
```

Both are listening inside the shared network namespace (replace `<PORT>`
with the announced port):

```sh
docker compose exec gluetun ss -lntup | grep -E "6878|<PORT>"
```

Playlists were generated and are served:

```sh
ls data/playlists/
curl -I http://localhost:8080/all.m3u
```

> The very first playlist may take a few minutes to appear (IPNS
> resolution). If it is missing, see
> [41 Common issues](../40-49-troubleshooting/41-common-issues.md).

## Point a client at it

Add `http://<HOST>:8080/all.m3u` (or a per-source file) to your IPTV
client. See [22 Clients](../20-29-operation/22-clients.md).
