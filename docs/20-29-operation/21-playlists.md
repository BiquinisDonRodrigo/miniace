# 21 Playlists

The playlist subsystem resolves the sources declared in `data/sources.json`,
rewrites AceStream entries so they point at your engine, and serves the
result over HTTP.

## `data/sources.json`

A JSON array of objects; `nombre` / `origen` are accepted as aliases of
`name` / `origin`:

```json
[
  {"name": "example", "origin": "ipns://<key>/playlist.m3u"},
  {"name": "iptv",    "origin": "ipns://<key>/channels.m3u"},
  {"name": "static",  "origin": "https://example.org/list.m3u"}
]
```

- `name` becomes the output file (`<name>.m3u`). It must not contain `/`
  or a null byte, must not start with a dot, and `all` is reserved for the
  merged playlist; spaces and accents are fine. Duplicated names are
  skipped (the first one wins).
- `origin` may be:
  - `ipns://<key>/<path>` — resolved through the local Kubo gateway
    (`IPFS_GATEWAY`, default `http://kubo:48080`), then through the public
    gateways listed in `IPFS_FALLBACK_GATEWAYS`.
  - `ipfs://<cid>/<path>` — same resolution path.
  - `http(s)://…` — fetched directly. Gateway-style URLs (`/ipfs/…` or
    `/ipns/…` paths, or `<root>.ipfs|ipns.<host>` subdomains) also go
    through the local Kubo gateway and the fallback list when the origin
    gateway itself does not answer.
- The file is re-read on **every sync cycle** (and every retry), so edits
  apply without a restart even while failed sources are being retried. To
  force a refresh immediately: `docker compose restart acestream`.
- A source that fails to fetch keeps its previous file; the other sources
  still update, and the failed ones are retried (only them) every
  `RETRY_INTERVAL` (60 s) until the next full cycle.

## Generated files

Under `data/playlists/` (gitignored):

| File | Content |
|---|---|
| `<name>.m3u` | One source, rewritten |
| `all.m3u` | Every configured source, from its latest successful fetch; first header kept |

Every AceStream entry — bare hash, `acestream://<hash>`, or an
`http(s)://…?id=…` / `?content_id=…` / `?infohash=…` URL — is rewritten to
`http://<request-host>:<PUBLIC_PORT>/ace/getstream?<selector>=<hash>`, where
`<request-host>` is the host used by the client that fetched the playlist.
The selector is preserved on purpose: outpace treats `id=` / `content_id=`
as a content id and `infohash=` as a bare swarm hash. Bare and
`acestream://` entries become `id=`. All other URLs (regular HLS streams,
etc.) are left untouched.

Because the rewrite happens **per request**, the same file works from the
LAN and from Tailscale at once: fetched via
`http://192.168.1.100:8080/all.m3u`, entries point to
`192.168.1.100:6878`; fetched via `http://100.64.x.x:8080/all.m3u`, they
point to `100.64.x.x:6878`.

On disk, files contain the placeholder `__MINIACE_HOST__`; the HTTP server
substitutes it per request.

## HTTP server

The playlist server is a small Python HTTP server (`sync.py`) listening on
container port 8080 and serving `data/playlists/`. It serves any file in
that directory; only `.m3u` files are rewritten, and `.m3u` is served as
`audio/x-mpegurl` so VLC opens it as a channel list.

```sh
curl -O http://<HOST>:8080/all.m3u
```

## First resolution

A fresh Kubo node must resolve the IPNS records from the network, which
can take minutes. Until then, sources may fail and the sync retries every
60 s. Once resolved, records are cached locally and refreshes are fast.
