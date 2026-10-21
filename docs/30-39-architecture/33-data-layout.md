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
    └── outpace/
        ├── identity.seed   # outpace node identity
        └── cache/          # recent peers + optional disk piece cache
```

| Path | Written by | Contents | Safe to delete |
|---|---|---|---|
| `sources.json` | you | Playlist sources | No — back it up |
| `playlists/` | `sync.py` | `<name>.m3u`, `all.m3u` | Yes (regenerated) |
| `gluetun/` | Gluetun | `forwarded_port`, `ip` | Yes (recreated) |
| `ipfs/` | Kubo | IPFS repo, node identity, IPNS records | No — cold start re-resolves everything |
| `acestream/outpace/identity.seed` | outpace | Node identity | Not recommended |
| `acestream/outpace/cache/` | outpace | Recent peers and optional disk piece cache | Yes (ephemeral) |

Notes:

- Docker creates missing bind-mount directories as root. Create `data/`
  yourself before the first `docker compose up` (see
  [12 Installation](../10-19-getting-started/12-installation.md)).
- `data/ipfs/` holds the node's identity. If you lose it, IPNS records
  must be resolved again from scratch, which can take minutes.
- `data/gluetun/forwarded_port` is one of the two sources the engine uses
  to learn the announced port; it is written by Gluetun.
- The outpace cache is bounded per active stream by
  `OUTPACE_SEED_STORE_BYTES` and `OUTPACE_SEED_RETENTION_SECS`; see
  [13 Configuration](../10-19-getting-started/13-configuration.md#stream-cache).
- Upgrading from a version that used the official engine leaves
  `data/acestream/state/` and `data/acestream/cache/` behind. outpace does
  not read them; they can be deleted once the new stack works.
