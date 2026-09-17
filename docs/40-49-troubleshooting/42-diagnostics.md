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

## Kubo

```sh
docker compose exec kubo ipfs id
docker compose exec kubo ipfs swarm peers | head
docker compose exec acestream curl -s -o /dev/null -w '%{http_code}\n' http://kubo:48080/
```

## Listening sockets

```sh
docker compose exec gluetun ss -lntup
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
