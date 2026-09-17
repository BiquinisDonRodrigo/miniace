# 41 Common issues

## No forwarded port

**Symptom:** `engine: no Gluetun forwarded port available yet; waiting` in
`docker compose logs acestream`, and the engine never starts.

**Causes:** ProtonVPN plan without port forwarding (free plan), the
WireGuard config was generated without **NAT-PMP (Port Forwarding)**, or
the selected server does not support it.

**Check:**

```sh
docker compose logs gluetun | grep -iE "port forward|natpmp|error"
```

miniace sets `PORT_FORWARD_ONLY=on` to filter for capable servers; if none
is found, try another `PROTON_COUNTRIES`.

## Playlist 404 / empty

**Symptoms:** `http://<HOST>:8080/all.m3u` returns 404 or an empty list,
and `data/playlists/` is empty.

**Causes:** no `data/sources.json` (it is gitignored and absent from fresh
clones), all sources failed to fetch, or the first IPNS resolution has not
finished (it can take minutes on a fresh Kubo repo).

**Check:**

```sh
docker compose logs acestream | grep sync
docker compose logs kubo
docker compose restart acestream    # force a sync cycle
```

## DNS errors at first boot

**Symptom:** `Temporary failure in name resolution` during the first sync
cycles.

**Cause:** the sync starts before Gluetun has the VPN/DNS ready.

**Fix:** none needed. The loop retries every `RETRY_INTERVAL` (60 s) until
at least one source is fetched.

## kubo unreachable from acestream

**Symptom:** fetches through `http://kubo:48080` fail and fall back to the
public gateways (slow).

**Cause:** `FIREWALL_OUTBOUND_SUBNETS` does not match the Compose network
subnet (`DOCKER_SUBNET`, default `172.30.0.0/24`).

**Check** (HTTP 404 means reachable):

```sh
docker compose exec acestream curl -s -o /dev/null -w '%{http_code}\n' http://kubo:48080/
```

## Streams fail from clients but work on the server

**Cause:** the client must reach the engine port (`ACESTREAM_HTTP_PORT`,
default 6878) on the same host it used to fetch the playlist, and the
engine needs inbound access to that port (`FIREWALL_INPUT_PORTS`).

**Check:** fetch the playlist with the exact host the client uses, then
open one of the rewritten URLs from the client. Avoid playlists fetched
via `localhost`.

## Container unhealthy

The healthcheck probes the playlist server, not the engine:

```sh
docker compose ps
docker compose logs acestream
```

If the server is up but the engine is waiting for a forwarded port, the
container stays healthy — that is expected.

## `docker compose pull` denied

The GHCR package is private by default. Make it public or run
`docker login ghcr.io`; see
[11 Requirements](../10-19-getting-started/11-requirements.md). Building
locally (`docker compose up -d --build`) avoids the registry entirely.

## Port already in use

Change `ACESTREAM_HTTP_PORT` / `PLAYLISTS_PORT` in `.env` and run
`docker compose up -d`. Container ports stay 6878/8080, so nothing else
needs editing.
