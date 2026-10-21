# 42 Diagnostics

All commands run from the repository root.

## Stack status

```sh
docker compose ps
docker compose logs --tail=100 gluetun acestream kubo
```

## Forwarded port

```sh
docker compose exec acestream curl -s http://127.0.0.1:8001/v1/portforward
docker compose exec acestream cat /tmp/gluetun/forwarded_port
docker compose exec acestream cat /tmp/miniace/gluetun_p2p_port
docker compose exec acestream cat /tmp/miniace/active_p2p_port
docker compose logs gluetun | grep -i "forwarded port"
```

## Engine

```sh
docker compose exec acestream curl -fsS http://127.0.0.1:6878/healthz
docker compose exec acestream curl -s \
  'http://127.0.0.1:6878/server/api?method=get_version'
docker compose logs acestream | grep -E "engine:|outpace:"
```

`/healthz` returns `ok` while the daemon is running. `get_version` is the
AceStream-compatible control route; outpace reports its own version.

## Active streams

```sh
docker compose exec acestream curl -s http://127.0.0.1:6878/streams
docker compose exec acestream curl -s \
  http://127.0.0.1:6878/streams/ace/<id>/status
```

`/streams` lists shared sessions with their network, id and client count.
The per-stream `/status` route exposes counters such as `speed_up`,
`speed_down`, `uploaded` and `peers` while the session is active.

## Playlists

```sh
curl -I http://localhost:8080/all.m3u
curl -s http://localhost:8080/all.m3u | head
ls -la data/playlists/
docker compose logs acestream | grep -E "sync|fetching"
```

## Upload throughput

Verify the forwarded port using
[32 P2P port forwarding](../30-39-architecture/32-p2p-port-forwarding.md#verify)
first. Then start a playback session and watch the outpace counters:

```sh
# list active streams and pick one id
docker compose exec acestream curl -s http://127.0.0.1:6878/streams

# poll the session counters (repeat every 5 s)
docker compose exec acestream curl -s \
  http://127.0.0.1:6878/streams/ace/<id>/status
```

`uploaded` is bytes; `speed_up` is KiB/s. For sustained upload in decimal
Mbps, use the change in `uploaded` over a measured interval:

```
Mbps = (uploaded_end - uploaded_start) * 8 / elapsed_seconds / 1000000
```

Allow a few minutes for the swarm to settle, then compare 10–15 minute
windows on the same stream and VPN server before and after tuning. Record
CPU, memory, disk activity and playback stalls alongside upload. A larger
peer budget only helps when peers request data and the host/VPN has spare
capacity.

Relevant outpace knobs: `OUTPACE_MAX_INBOUND`, `OUTPACE_MAX_ACTIVE_UPSTREAMS`,
`OUTPACE_SEED_STORE_BYTES`, `OUTPACE_SEED_RETENTION_SECS` and
`OUTPACE_PREBUFFER_BYTES`. See
[13 Configuration](../10-19-getting-started/13-configuration.md#outpace-tuning).
There is no adaptive slot manager in outpace, so the old
`ACESTREAM_SLOTS_MANAGER_*` variables do not apply.

## Kubo

```sh
docker compose exec kubo ipfs id
docker compose exec kubo ipfs swarm peers | head
docker compose exec acestream curl -s -o /dev/null -w '%{http_code}\n' http://kubo:48080/
```

## Listening sockets

```sh
docker compose exec acestream ss -lntup
```

## Disk

```sh
du -sh data/*
du -sh data/acestream/outpace data/ipfs
```

## Reporting a problem

Include:

- host OS and architecture (`uname -a`, `getconf PAGESIZE` on ARM);
- the output of `docker compose logs` for the affected service;
- whether the issue appears on first boot or after an update;
- the output of `docker compose exec acestream curl -s http://127.0.0.1:6878/healthz`;
- `docker compose config` if relevant — **redact `WG_PRIVATE_KEY`** before
  pasting it anywhere.

Open an issue at <https://github.com/BiquinisDonRodrigo/miniace/issues>.
