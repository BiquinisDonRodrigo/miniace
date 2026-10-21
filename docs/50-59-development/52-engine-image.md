# 52 The engine image

`images/outpace/` is the only custom image in the stack. It bundles the
outpace engine, the Gluetun port supervisor and the playlist sync/server in
a single container, and is built for `linux/amd64`, `linux/arm64` and
`linux/arm/v7`.

## Dockerfile

- Stage `outpace`: `ghcr.io/jamezrin/outpace` pinned by the v0.5.0
  multi-arch index digest. It provides the static `outpace` binary and its
  AGPL-3.0 licence.
- Final base: `python:3.10-slim` (the playlist sync uses only the standard
  library).
- Installs `curl` and `iproute2` (the base image already ships CA
  certificates); no Python packages and no engine tarball are downloaded.
- Copies `outpace` to `/opt/miniace/outpace`, the licence to
  `/usr/share/doc/outpace/LICENSE` and the image notice to
  `/usr/share/doc/outpace/NOTICE`.
- Copies `entrypoint.sh`, `outpace.sh` and `sync.py` to `/opt/miniace/`.
- Healthcheck: `curl -fsS http://127.0.0.1:8080/` (playlist server).
- Entrypoint: `entrypoint.sh`.

The outpace binary is static (musl), so the same artifact runs on the glibc
base image. The image is tagged
`ghcr.io/biquinisdonrodrigo/miniace:latest`.

## entrypoint.sh

Sources `outpace.sh`, then runs:

- `start_engine &` — the outpace supervisor;
- `port_watch_loop &` — the port rotation watcher;
- `python3 -u /opt/miniace/sync.py` in the foreground; when it exits, the
  container shuts down. A `TERM`/`INT` trap stops the engine and the sync.

## outpace.sh

Pure function and variable definitions (no side effects when sourced):

| Function | Role |
|---|---|
| `validate_outpace_config` | Rejects malformed tuning values and missing binary |
| `query_gluetun_port` | Resolves the announced port (control API → legacy route → status file) |
| `is_valid_port` | Validates a TCP port number |
| `outpace_alive` | Probes `GET /healthz` |
| `outpace_pids` / `stop_engine` / `sweep_engine_leftovers` | Process management via `/proc` (the image ships no `ps`) |
| `start_outpace` | Spawns `outpace serve` with the forwarded P2P port and the `OUTPACE_*` environment |
| `start_engine` | Supervisor loop: resolve port → spawn → readiness probe → backoff on crashes |
| `port_watch_loop` | Detects rotations and restarts the engine |
| `engine_init` | Validates configuration, creates data/cache dirs and checks Gluetun |

The supervisor forces `OUTPACE_EXPERIMENTAL_ACE_COMPAT=1` (the
`/ace/getstream` contract used by the playlists),
`OUTPACE_ENABLE_PORT_MAPPING=0` (Gluetun owns NAT-PMP) and
`OUTPACE_BIND=0.0.0.0:6878`. Behavior details in
[32 P2P port forwarding](../30-39-architecture/32-p2p-port-forwarding.md).

## sync.py

- Reads `SOURCES_FILE` (`/data/sources.json`), fetches each origin through
  the Kubo gateway with public fallbacks, validates `#EXTM3U`, rewrites
  AceStream entries to
  `http://__MINIACE_HOST__:<PUBLIC_PORT>/ace/getstream?<selector>=<hash>`
  and atomically writes `PLAYLISTS_DIR/<name>.m3u`. Each source is refreshed
  independently; a failure never aborts the others.
- Preserves the source selector: `id=` / `content_id=` address a content
  id, `infohash=` addresses a bare swarm hash. Bare and `acestream://`
  entries become `id=`.
- Rebuilds `all.m3u` from the latest `<name>.m3u` of every configured
  source, so a source that failed keeps its last known channels.
- Runs a sync thread (full cycle every `SYNC_INTERVAL`, failed sources
  retried every `RETRY_INTERVAL` until the next full cycle) and a
  `ThreadingHTTPServer` on `HTTP_PORT` (8080) that substitutes
  `__MINIACE_HOST__` with the request's `Host` header per request.

## Build and test locally

```sh
docker compose build acestream                  # build with the compose context
docker compose up -d --build                    # rebuild and run the whole stack
docker build -t miniace-test images/outpace     # image only
```

To build the multi-arch manifest locally (requires Buildx and QEMU for the
ARM targets):

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t miniace-test images/outpace
```

See [53 CI/CD](53-ci-cd.md) for the published platforms.

## Validation checklist

Before publishing a new outpace digest or engine change:

1. Build all three platforms:
   `docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 images/outpace`.
2. amd64: start the stack, confirm the playlist server on `:8080`, `/healthz`
   on `:6878`, and play a real channel through a rewritten playlist URL.
3. arm64: repeat on real hardware when available (QEMU is only a
   compatibility smoke test, not a performance test).
4. armv7: start the image under QEMU and check `/healthz`; do not draw
   throughput conclusions from emulation.
5. Rotate the forwarded port (edit `data/gluetun/forwarded_port` or restart
   Gluetun) and confirm the supervisor respawns outpace on the new port.
6. Check `docker stats` and the `/streams` counters with several concurrent
   streams, especially on ARM.

## Licence

outpace is **AGPL-3.0-or-later**. The image redistributes its unmodified
binary; the licence and source reference are included in the image and in
[NOTICE](../../NOTICE). miniace's own scripts remain MIT.
