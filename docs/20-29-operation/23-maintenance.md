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

`data/` (sources, playlists, engine state, IPFS repository) is untouched by
updates.

## Logs

```sh
docker compose logs -f acestream     # engine supervisor + playlist sync
docker compose logs -f gluetun       # VPN, NAT-PMP, firewall
docker compose logs -f kubo          # IPFS node
```

The engine also writes a rotating log (10 MB, 1 backup) to
`data/acestream/state/acestream.log`. The playlist sync logs to the
container's stdout.

## Health

The `acestream` container is healthy while the playlist server answers on
`:8080`:

```sh
docker compose ps
curl -fsS http://localhost:8080/ >/dev/null && echo "playlists OK"
```

## Backups

Only user data matters:

| Path | Why |
|---|---|
| `data/sources.json` | **Not in git** (the whole `data/` tree is gitignored). Back it up. |
| `data/ipfs/` | Kubo repository and node identity. Losing it forces a slow IPNS re-resolution from the network. |
| `data/playlists/` | Regenerated automatically. |
| `data/acestream/` | Engine state and cache; the cache is rebuilt on demand. |

## Cache

The engine disk cache gives upload reciprocity (better peers). It is
limited to `ACESTREAM_CACHE_LIMIT_GB` (default 5 GB). Set it to `0` to
disable it, or clear it manually:

```sh
docker compose stop acestream
rm -rf data/acestream/cache/*
docker compose start acestream
```

## Port rotations

ProtonVPN rotates the forwarded port on every reconnect. The port watcher
detects the change within `PORT_WATCH_INTERVAL_S` (default 45 s) and
restarts the engine bound to the new port; players reconnect on their own.
A brief interruption is expected.

## Changing VPN location

Edit `PROTON_COUNTRIES` in `.env` and recreate the stack:

```sh
docker compose up -d
```

A new server means a new forwarded port; the engine rebinds automatically.
