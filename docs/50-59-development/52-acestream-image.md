# 52 The acestream image

`images/acestream/` is the only custom image in the stack. It bundles the
official AceStream engine, the Gluetun port supervisor and the playlist
sync/server in a single container.

## Dockerfile

- Base: `python:3.10-slim` (the engine tarball ships Python 3.10 code).
- Downloads the official engine tarball
  (`acestream_3.2.11_ubuntu_22.04_x86_64_py3.10.tar.gz`) and verifies it
  against a pinned SHA256 (`ACESTREAM_URL` / `ACESTREAM_SHA256` build
  args). The tarball is not redistributed.
- Installs `ca-certificates curl iproute2` plus the pinned Python
  dependencies from `requirements.txt`.
- Copies `engine.sh`, `entrypoint.sh`, `configure_engine.py` and `sync.py`
  to `/opt/miniace/`.
- Healthcheck: `curl -fsS http://127.0.0.1:8080/` (playlist server).
- Entrypoint: `entrypoint.sh`.

## entrypoint.sh

Sources `engine.sh`, then runs:

- `start_engine &` — the engine supervisor;
- `port_watch_loop &` — the port rotation watcher;
- `python3 -u /opt/miniace/sync.py` in the foreground; when it exits, the
  container shuts down. A `TERM`/`INT` trap stops the engine and the sync.

## engine.sh

Pure function and variable definitions (no side effects when sourced):

| Function | Role |
|---|---|
| `query_gluetun_port` | Resolves the announced port (control API → legacy route → status file) |
| `engine_api_alive` | Probes the engine HTTP API |
| `engine_pids` / `stop_engine` / `sweep_engine_leftovers` | Process management via `/proc` (the image ships no `ps`) |
| `validate_engine_config` | Rejects malformed tuning values, invalid enums and managed flags duplicated in `ACESTREAM_EXTRA_FLAGS` |
| `build_engine_flags` | Builds `ENGINE_FLAGS`: state, rate limits, connection/slot budgets, slot-manager tuning, cache backend/sizes, logging and extra passthrough flags |
| `configure_engine` | Invokes the authenticated settings helper after HTTP readiness |
| `start_engine` | Supervisor loop: resolve port → spawn engine → backoff on crashes |
| `port_watch_loop` | Detects rotations and restarts the engine |
| `engine_init` | Validates configuration, creates state/cache dirs, logs the upload profile and checks Gluetun |

Behavior details in
[32 P2P port forwarding](../30-39-architecture/32-p2p-port-forwarding.md).

## configure_engine.py

Reads the engine's per-run token from `engine_runtime.json` and uses
`GET/PATCH /api/v1/settings` on loopback to apply the client settings miniace
manages: connection/peer budgets, manual slot ceiling, rate limits, adaptive
slots, cache backends/sizes and the VOD buffer. Requests use the `x-api-key`
header and `Accept: application/json`. It changes only the managed settings
and verifies the response; other persisted settings survive.

Exit status `0` means the current settings match; `10` means settings were
saved and the supervisor must restart to load them into native preferences;
`1` indicates a configuration failure. The native Desktop client overwrites
some CLI preferences from player settings during initialization, and its
total connection limit requires a restart after an API update.

## sync.py

- Reads `SOURCES_FILE` (`/data/sources.json`), fetches each origin through
  the Kubo gateway with public fallbacks, validates `#EXTM3U`, rewrites
  AceStream entries to
  `http://__MINIACE_HOST__:<PUBLIC_PORT>/ace/getstream?id=<hash>` and
  atomically writes `PLAYLISTS_DIR/<name>.m3u` plus `all.m3u`.
- Runs a sync thread (`SYNC_INTERVAL`, retrying after `RETRY_INTERVAL`
  when a cycle fetches nothing) and a `ThreadingHTTPServer` on `HTTP_PORT`
  (8080) that substitutes `__MINIACE_HOST__` with the request's `Host`
  header per request.

## Build and test locally

```sh
docker compose build acestream                  # build with the compose context
docker compose up -d --build                    # rebuild and run the whole stack
docker build -t miniace-test images/acestream   # image only
```

The image targets `linux/amd64` only; see [53 CI/CD](53-ci-cd.md).
