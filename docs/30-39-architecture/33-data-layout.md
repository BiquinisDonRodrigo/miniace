# 33 Data layout

Everything persistent lives under `data/`, bind-mounted into the
containers. The whole directory is gitignored.

```text
data/
├── sources.json    # playlist sources (yours, not in git)
├── playlists/      # generated .m3u files (regenerated)
├── gluetun/        # forwarded_port + ip status files (runtime)
├── ipfs/           # Kubo repository (runtime, back it up)
└── acestream/
    ├── state/      # engine keys, databases and rotating log
    └── cache/      # engine disk cache (safe to delete)
```

| Path | Written by | Contents | Safe to delete |
|---|---|---|---|
| `sources.json` | you | Playlist sources | No — back it up |
| `playlists/` | `sync.py` | `<name>.m3u`, `all.m3u` | Yes (regenerated) |
| `gluetun/` | Gluetun | `forwarded_port`, `ip` | Yes (recreated) |
| `ipfs/` | Kubo | IPFS repo, node identity, IPNS records | No — cold start re-resolves everything |
| `acestream/state/` | engine | keys, databases, `acestream.log` | Not recommended (engine identity) |
| `acestream/cache/` | engine | downloaded pieces | Yes |

Notes:

- Docker creates missing bind-mount directories as root. Create `data/`
  yourself before the first `docker compose up` (see
  [12 Installation](../10-19-getting-started/12-installation.md)).
- `data/ipfs/` holds the node's identity. If you lose it, IPNS records
  must be resolved again from scratch, which can take minutes.
- `data/gluetun/forwarded_port` is one of the three sources the engine
  uses to learn the announced port; it is written by Gluetun.
- The engine cache is bounded by `ACESTREAM_CACHE_LIMIT_GB` (default
  5 GB); see [23 Maintenance](../20-29-operation/23-maintenance.md).
