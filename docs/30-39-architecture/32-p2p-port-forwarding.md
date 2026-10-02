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
   shared network namespace). A missing port (`"port":0`) or a failed
   request counts as "not available".
2. The status file `/tmp/gluetun/forwarded_port` (from the shared volume
   `data/gluetun/`).

The resolved value is cached in `$STATE_DIR/gluetun_p2p_port`
(`/tmp/miniace/`), and the port the engine is currently bound to is kept
in `$STATE_DIR/active_p2p_port`.

## Supervision

The supervisor probes the HTTP API for readiness instead of blocking on
the launcher PID, supporting both foreground and daemonizing launchers:

- Engine flags use `--flag=value`; the native bootstrap parses performance
  preferences, and the client parses HTTP/P2P options:
  `--client-console --bind-all --disable-sentry --log-stdout
  --log-stdout-level=info --log-file=<state>/acestream.log --vod-buffer=30
  --http-port=<API> --port=<forwarded> --state-dir=… --cache-dir=…`.
  `build_engine_flags` also adds cache backend/size, the rate limits and the
  [upload-first profile](../10-19-getting-started/13-configuration.md#upload-first-profile)
  (`--upload-limit`, `--max-connections=2000 --max-peers=100
  --max-peers-limit=500 --startup-max-peers=100 --startup-upload-slots=50
  --fix-upload-slots=1 --slots-manager-use-cpu-limit=0` by default), plus any
  `ACESTREAM_EXTRA_FLAGS` tokens appended last (the last occurrence wins;
  managed options are rejected by validation). See
  [13 Configuration](../10-19-getting-started/13-configuration.md#engine-option-surface)
  for the full variable-to-flag map.
  Arguments are passed as an array so paths containing spaces remain intact.
- The supervisor allows up to 60 seconds for HTTP readiness. Once ready,
  `configure_engine.py` applies the client settings through the local API;
  saved changes cause one restart to load the native connection budget.
  Settings are verified again after the restart. A failed configuration
  attempt also restarts before retrying, including after a partial update.
- Orphan daemons from previous runs are swept before each start (they keep
  holding the P2P port and wedge fresh starts).
- Crashes back off exponentially (3 → 60 s); restarts caused by a port
  rotation respawn immediately.

## Rotation watcher

ProtonVPN rotates the port on reconnect. `port_watch_loop` polls every
`PORT_WATCH_INTERVAL_S` (default 10 s); when the announced port differs
from `active_p2p_port`, it stops the engine and the supervisor respawns it
bound to the new port. In-flight streams are interrupted for a few
seconds.

## NAT-PMP renewal hiccups

Gluetun refreshes the NAT-PMP mapping every 45 s for a 60 s lease.
ProtonVPN gateways occasionally refuse a renewal datagram; the pinned
Gluetun build retries refused datagrams like timeouts
([gluetun #3464](https://github.com/passteque/gluetun/pull/3464)), so a
single hiccup no longer tears the mapping down and the announced port
stays stable. An outage that outlasts the retry window (persistent
`i/o timeout`) clears the port until the next successful negotiation,
which recovers on its own. See
[41 Common issues](../40-49-troubleshooting/41-common-issues.md).

## Verify

```sh
docker compose logs gluetun | grep -i "forwarded port"       # announced port N
docker compose logs acestream | grep "P2P on forwarded"      # engine bound to N
docker compose exec acestream ss -lntup | grep -E "6878|<N>" # both listening
docker compose exec acestream curl -s http://127.0.0.1:8001/v1/portforward
```

The listening sockets and matching port numbers check the local binding.
From a machine outside the VPN tunnel, probe `<VPN-public-IP>:<N>` with
`nc -vz <VPN-public-IP> <N>` to check TCP reachability through the forwarded
port. Use the VPN exit address, not the Docker host's LAN/WAN address.
UDP reachability needs a separate UDP exchange; a listening UDP socket alone
does not establish it. Gluetun manages the forwarded VPN firewall port;
`FIREWALL_INPUT_PORTS` controls the published client-facing HTTP ports.

If no port is ever announced, see
[41 Common issues](../40-49-troubleshooting/41-common-issues.md).
