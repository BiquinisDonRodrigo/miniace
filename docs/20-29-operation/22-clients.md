# 22 Clients

## URLs

| Purpose | URL |
|---|---|
| Merged playlist | `http://<HOST>:8080/all.m3u` |
| Single source | `http://<HOST>:8080/<name>.m3u` |
| Stream endpoint (embedded in playlists) | `http://<HOST>:6878/ace/getstream?id=<infohash>` |

`<HOST>` is the address of the Docker host as seen by the client: its LAN
IP (`192.168.x.x`), a Tailscale address (`100.64.x.x`) or a DNS name.

**Use the same host for the playlist and for playback.** Playlists rewrite
stream URLs to the host used to fetch them, so a playlist fetched from the
LAN points at LAN addresses, and one fetched through Tailscale points at
Tailscale addresses. A playlist fetched via `localhost` will not work for
other devices.

If you changed `ACESTREAM_HTTP_PORT` in `.env`, replace `6878` with your
host port.

## TiviMate

1. Add playlist → M3U playlist → URL: `http://<HOST>:8080/all.m3u`.
2. Optionally set an EPG source; miniace only serves channel lists.

## VLC

Open network stream → `http://<HOST>:8080/all.m3u`, or paste an individual
`http://<HOST>:6878/ace/getstream?id=<infohash>` URL.

## Jellyfin

Add an M3U tuner pointing at `http://<HOST>:8080/all.m3u`. Streams are
proxied through the engine, so no AceStream plugin is required on the
client side.

## Firewall

Gluetun's `FIREWALL_INPUT_PORTS=6878,8080` allows LAN clients to reach the
published ports. Those are container ports, which do not change when you
remap host ports in `.env`, so this line rarely needs editing. If a client
cannot connect while the server can, see
[41 Common issues](../40-49-troubleshooting/41-common-issues.md).
