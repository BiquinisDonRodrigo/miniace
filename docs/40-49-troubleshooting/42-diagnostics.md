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
docker compose exec acestream curl -s \
  'http://127.0.0.1:6878/webui/api/service?method=get_version'
docker compose logs acestream | grep -E "engine:|P2P on forwarded"
```

## Playlists

```sh
curl -I http://localhost:8080/all.m3u
curl -s http://localhost:8080/all.m3u | head
ls -la data/playlists/
docker compose logs acestream | grep -E "sync|fetching"
```

## Upload throughput

First verify the forwarded port using
[32 P2P port forwarding](../30-39-architecture/32-p2p-port-forwarding.md#verify).
Check the requested profile and container resources during playback:

```sh
docker compose logs acestream | grep -E 'engine: (upload profile:|client settings verified)'
docker compose exec acestream sh -c 'ulimit -Sn; ulimit -Hn'
docker stats miniace-acestream miniace-gluetun
```

To trace the slot manager itself, enable its debug switch and verbose
logging, then watch the engine log during an active session:

```sh
# in .env, then: docker compose up -d
ACESTREAM_LOG_STDOUT_LEVEL=debug
ACESTREAM_EXTRA_FLAGS="--debug-upload-slots=1"
# ...
docker compose logs -f acestream | grep -E 'check_upload_slots|rechoke'
```

`check_upload_slots: skip raise` / `decrease slots` / `change max peers`
lines distinguish adaptive growth from CPU-based reduction. Remove both
settings afterwards; debug logging is verbose.

For per-stream P2P measurements, start a playback session with
`GET /ace/getstream?id=<content_id>&format=json`. Its `response` object
contains `playback_url` and `stat_url`. Play the returned `playback_url` and
poll that session's `stat_url` every 5 seconds, for example:

```sh
docker compose exec acestream curl -fsS \
  'http://127.0.0.1:6878/ace/stat/<infohash>/<playback_session_id>'
```

Record `response.speed_up`, `response.uploaded` and `response.peers` along
with timestamps. For sustained upload in decimal Mbps, use the change in
`uploaded` (bytes) over a measured interval:

```
Mbps = (uploaded_end - uploaded_start) * 8 / elapsed_seconds / 1000000
```

Allow a few minutes for the swarm to settle, then compare 10-15 minute
windows on the same stream and VPN server before and after tuning. Record
CPU, memory, disk activity and playback stalls alongside upload. A larger
peer budget only helps when peers request data and the host/VPN has spare
capacity. An idle engine has no active playback traffic to benchmark.

Inspect engine slot-manager messages when detailed engine logging is
available: `check_upload_slots`, `skip raise`, `decrease slots`, and
`change max peers` distinguish adaptive growth from CPU-based reduction.
The supervisor's profile line shows requested settings; it is not a
measurement of active slots or throughput.
`client settings verified` confirms that the settings API reports the
requested client values. `restarting to load saved client settings` is
expected once when those values change: the total connection budget is
loaded into native preferences at engine startup.

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
du -sh data/acestream/cache data/ipfs
```

## Reporting a problem

Include:

- host OS and architecture (`uname -a`);
- the output of `docker compose logs` for the affected service;
- whether the issue appears on first boot or after an update;
- `docker compose config` if relevant — **redact `WG_PRIVATE_KEY`** before
  pasting it anywhere.

Open an issue at <https://github.com/BiquinisDonRodrigo/miniace/issues>.
