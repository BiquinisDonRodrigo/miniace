# 23 Maintenance

## Update

```sh
docker compose pull
docker compose up -d
```

To build the `acestream` image locally instead:

```sh
docker compose up -d --build --pull
```

`data/` (sources, playlists, engine identity, IPFS repository) is untouched
by updates.

## Logs

```sh
docker compose logs -f acestream     # outpace + engine supervisor + playlist sync
docker compose logs -f gluetun       # VPN, NAT-PMP, firewall
docker compose logs -f kubo          # IPFS node
```

outpace logs to the container's stdout; there is no rotating engine log file
inside the container. Compose caps the `acestream` json-file log at 10 MB
with 3 files.

## Health

The `acestream` container is healthy while the playlist server answers on
`:8080`:

```sh
docker compose ps
curl -fsS http://localhost:8080/ >/dev/null && echo "playlists OK"
docker compose exec acestream curl -fsS http://127.0.0.1:6878/healthz
```

## Backups

Only user data matters:

| Path | Why |
|---|---|
| `data/sources.json` | **Not in git** (the whole `data/` tree is gitignored). Back it up. |
| `data/ipfs/` | Kubo repository and node identity. Losing it forces a slow IPNS re-resolution from the network. |
| `data/playlists/` | Regenerated automatically. |
| `data/acestream/outpace/identity.seed` | outpace node identity. |
| `data/acestream/outpace/cache/` | Ephemeral; rebuilt on demand. |

## Cache

Retained pieces are configured with `OUTPACE_CACHE_TYPE` (`memory` by
default, or `disk`), `OUTPACE_SEED_STORE_BYTES` and
`OUTPACE_SEED_RETENTION_SECS`; see
[13 Configuration](../10-19-getting-started/13-configuration.md#stream-cache).
The budget is per active stream, not a global quota. To clear the on-disk
cache manually:

```sh
docker compose stop acestream
rm -rf data/acestream/outpace/cache/*
docker compose start acestream
```

outpace writes its `.outpace-cache` sentinel on the next disk-mode start.

## Port rotations

ProtonVPN rotates the forwarded port on every reconnect. The port watcher
checks for changes every `PORT_WATCH_INTERVAL_S` (default 10 s) and
restarts the engine bound to the new port; players reconnect on their own.
A brief interruption is expected.

## Changing VPN location

Edit `PROTON_COUNTRIES` in `.env` and recreate the stack:

```sh
docker compose up -d
```

A new server means a new forwarded port; the engine rebinds automatically.
