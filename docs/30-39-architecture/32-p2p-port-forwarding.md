# 32 P2P port forwarding

AceStream is a P2P protocol: to download from peers it must accept inbound
connections. ProtonVPN does not provide a static inbound port; it announces
one via **NAT-PMP**, negotiated by Gluetun, and rotates it on every
reconnect.

miniace therefore has one hard rule: **the engine only ever binds the port
announced by ProtonVPN.** There is no fallback to a static port (e.g.
8621). While no forwarded port exists, the engine simply does not start.

## How the port is resolved

`query_gluetun_port()` in `images/acestream/engine.sh` tries, in order:

1. Gluetun control API `GET /v1/portforward` (loopback `:8001` inside the
   shared network namespace).
2. Legacy route `GET /v1/port_forwarded`.
3. The status file `/tmp/gluetun/forwarded_port` (from the shared volume
   `data/gluetun/`).

The resolved value is cached in `$STATE_DIR/gluetun_p2p_port`
(`/tmp/miniace/`), and the port the engine is currently bound to is kept
in `$STATE_DIR/active_p2p_port`.

## Supervision

The `start-engine` launcher daemonizes, so the supervisor probes the HTTP
API instead of trusting a PID:

- Engine flags (value flags use the `--flag=value` form parsed by
  `Plugin/BackgroundProcess.py` in the engine distribution):
  `--client-console --bind-all --disable-sentry --log-stdout
  --log-stdout-level=info --log-file=<state>/acestream.log --vod-buffer=30
  --http-port=<API> --port=<forwarded> [--cache-dir=… --cache-limit=…]`
- Orphan daemons from previous runs are swept before each start (they keep
  holding the P2P port and wedge fresh starts).
- Crashes back off exponentially (3 → 60 s); restarts caused by a port
  rotation respawn immediately.

## Rotation watcher

ProtonVPN rotates the port on reconnect. `port_watch_loop` polls every
`PORT_WATCH_INTERVAL_S` (default 45 s); when the announced port differs
from `active_p2p_port`, it stops the engine and the supervisor respawns it
bound to the new port. In-flight streams are interrupted for a few
seconds.

## Verify

```sh
docker compose logs gluetun | grep -i "forwarded port"       # announced port N
docker compose logs acestream | grep "P2P on forwarded"      # engine bound to N
docker compose exec gluetun ss -lntup | grep -E "6878|<N>"   # both listening
docker compose exec acestream curl -s http://127.0.0.1:8001/v1/portforward
```

If no port is ever announced, see
[41 Common issues](../40-49-troubleshooting/41-common-issues.md).
