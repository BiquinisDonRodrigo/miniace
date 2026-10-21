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

## NAT-PMP renewal errors (`connection refused` / `i/o timeout`)

**Symptom:** recurring lines in `docker compose logs gluetun` pointing at
the VPN gateway's NAT-PMP responder:

```text
ERROR [port forwarding] adding port mapping: ... read udp
10.2.0.2:x->10.2.0.1:5351: recvfrom: connection refused
INFO  [firewall] removing allowed port <N>...
INFO  [port forwarding] port forwarded is <N>   # seconds later
```

**Cause:** Gluetun refreshes the NAT-PMP mapping every 45 s for a 60 s
lease, and ProtonVPN gateways occasionally drop or refuse one renewal
datagram. Builds without the refused-retry fix escalated a single refused
datagram to a full teardown (firewall rule removed, port file cleared)
until the next successful negotiation — even though the gateway hands the
same port back. The `+pmp` hint in the error text is OpenVPN-specific and
does not apply to WireGuard.

**Fix:** run a Gluetun build with the refused-retry logic
([gluetun #3464](https://github.com/passteque/gluetun/pull/3464), fixing
[#3462](https://github.com/passteque/gluetun/issues/3462)); the digest
pinned in `docker-compose.yml` includes it. Refused renewals are retried
internally, so the announced port stays stable. Persistent `i/o timeout`
outages mean the gateway is unreachable; they recover on their own.

**Check:**

```sh
docker compose logs gluetun | grep -iE "port forwarded|refused|timeout"
docker compose exec acestream curl -s http://127.0.0.1:8001/v1/portforward
```

## Playlist 404 / empty

**Symptoms:** `http://<HOST>:8080/all.m3u` returns 404 or an empty list,
and `data/playlists/` is empty.

**Causes:** no `data/sources.json` (it is gitignored and absent from fresh
clones), all sources failed to fetch, or the first IPNS resolution has not
finished (it can take minutes on a fresh Kubo repo).

`data/sources.json` is re-read on every sync cycle and every retry
(`RETRY_INTERVAL`, 60 s) — including when the file is missing or invalid —
so creating or fixing it applies without a restart.

**Check:**

```sh
docker compose logs acestream | grep sync
docker compose logs kubo
docker compose restart acestream    # force a sync cycle
```

## Stream does not play or the content id cannot be resolved

**Symptoms:** the playlist loads and clients receive the rewritten URL, but
playback fails or stalls, and the acestream log shows a catalog or
descriptor resolution failure.

**Cause:** outpace is an independent reimplementation of the public
AceStream live path. It resolves content ids through the signed catalog and
targets public, unencrypted live streams; premium/account streams and some
legacy or unusual transports are out of scope. A catalog outage or a stale
content id also fails closed.

**Check:**

```sh
docker compose exec acestream curl -fsS http://127.0.0.1:6878/healthz
docker compose exec acestream curl -s 'http://127.0.0.1:6878/server/api?method=get_version'
docker compose logs acestream | grep -iE 'catalog|descriptor|resolution|error'
```

Test the id directly on the native route (the compatibility route is
`/ace/getstream`):

```sh
curl -v 'http://127.0.0.1:6878/streams/ace/cid:<content-id>.ts' -o /dev/null
```

If the native route works but the playlist URL does not, fetch the playlist
with the same host the client uses and verify the rewritten selector. Bare
`acestream://` entries become `id=`; sources that used `infohash=` keep
`infohash=`.

## Old `ACESTREAM_*` tuning has no effect

**Symptom:** changing `ACESTREAM_MAX_CONNECTIONS`, `ACESTREAM_CACHE_LIMIT_GB`,
`ACESTREAM_UPLOAD_LIMIT`, slot-manager variables or `ACESTREAM_EXTRA_FLAGS`
does nothing after upgrading.

**Cause:** miniace now runs outpace on every architecture. Those variables
configured the official engine and are no longer read. The current knobs are
`OUTPACE_*`; see
[13 Configuration](../10-19-getting-started/13-configuration.md#outpace-tuning)
and the migration table there.

## 16 KiB-page ARM kernels

outpace does not embed the Android libraries that break some third-party ARM
AceStream images on 16 KiB-page kernels, but upstream has not formally
qualified that configuration. If the engine starts but playback fails on a
16 KiB-page kernel, test the same stream on a 4 KiB-page host before filing
a bug.

## Public gateway fallbacks fail (HTTP 429/403)

**Symptom:** the sync log shows fallback fetches answered with
`HTTP Error 429` or `HTTP Error 403` (or a redirect to `dweb.link`), and
only the local Kubo gateway works.

**Cause:** ipfs.io, dweb.link and w3s.link were retired on 2026-09-21.
w3s.link only redirects to the retired dweb.link. miniace now defaults to
`https://ipfs.filebase.io`, but an `.env` copied from an older version
still carries the old list (its value overrides the new default).

**Fix:** edit `IPFS_FALLBACK_GATEWAYS` in `.env`, remove the retired
gateways and re-create the stack (`docker compose up -d`). Any gateway you
add must serve both `/ipfs/` and `/ipns/` paths.

## DNS errors at first boot

**Symptom:** `Temporary failure in name resolution` during the first sync
cycles.

**Cause:** the sync starts before Gluetun has the VPN/DNS ready.

**Fix:** none needed. Failed sources are retried every `RETRY_INTERVAL`
(60 s) — the whole cycle if `sources.json` itself cannot be read — until
they succeed.

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

The GHCR package is public, so a denial usually means you are logged in to
ghcr.io with an expired or insufficient token: run `docker logout ghcr.io`
and retry, or build locally (`docker compose up -d --build`) to avoid the
registry entirely.

## Port already in use

Change `ACESTREAM_HTTP_PORT` / `PLAYLISTS_PORT` in `.env` and run
`docker compose up -d`. Container ports stay 6878/8080, so nothing else
needs editing.
