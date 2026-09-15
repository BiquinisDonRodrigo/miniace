#!/usr/bin/env python3
"""miniace playlist sync.

Reads the M3U sources declared in SOURCES_FILE (default /data/sources.json),
resolves IPFS/IPNS origins through the local Kubo gateway (falling back to
public gateways), rewrites every AceStream entry so it points at the local
engine HTTP API, using the host of each HTTP request
(http://<request-host>:PUBLIC_PORT/ace/getstream?id=<hash>), and publishes the
results:

  * on disk, under PLAYLISTS_DIR (<name>.m3u per source + all.m3u merged)
  * over HTTP on :HTTP_PORT, serving PLAYLISTS_DIR

sources.json is re-read on every cycle, so it can be edited live:

    [
      {"name": "example", "origin": "ipns://<key>/playlist.m3u"},
      {"name": "iptv", "origin": "ipns://<key>/channels.m3u"}
    ]

"nombre"/"origen" are accepted as aliases of "name"/"origin".
"""

import io
import json
import logging
import os
import re
import signal
import tempfile
import threading
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

SOURCES_FILE = os.environ.get("SOURCES_FILE", "/data/sources.json")
PLAYLISTS_DIR = os.environ.get("PLAYLISTS_DIR", "/data/playlists")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "3600"))
FETCH_TIMEOUT = int(os.environ.get("FETCH_TIMEOUT", "120"))
HOST_TOKEN = "__MINIACE_HOST__"
PUBLIC_PORT = (os.environ.get("PUBLIC_PORT") or "6878").strip()

IPFS_GATEWAY = os.environ.get("IPFS_GATEWAY", "http://kubo:48080").rstrip("/")
IPFS_FALLBACK_GATEWAYS = [
    gateway.rstrip("/")
    for gateway in os.environ.get(
        "IPFS_FALLBACK_GATEWAYS",
        "https://ipfs.filebase.io,https://ipfs.io,https://dweb.link,https://w3s.link",
    ).split(",")
    if gateway.strip()
]

INFOHASH_RE = re.compile(r"[0-9a-fA-F]{40}")


class _RedirectHandler(urllib.request.HTTPRedirectHandler):
    """Extend urllib with 308 (Permanent Redirect) support.

    Public IPFS gateways (w3s.link) answer with 308, which stock urllib
    raises on instead of following.
    """

    def http_error_308(self, req, fp, code, msg, headers):
        return self.http_error_307(req, fp, code, msg, headers)


OPENER = urllib.request.build_opener(_RedirectHandler())

log = logging.getLogger("miniace")

stop_event = threading.Event()


def extract_infohash(entry):
    """Return the 40-hex AceStream infohash encoded in a playlist URL.

    Understands bare hashes, acestream:// links and http(s):// URLs that
    carry the hash in an id/infohash/content_id query parameter. Returns
    None for anything else (regular HLS/HTTP streams are left untouched).
    """
    entry = entry.strip()
    if not entry or entry.startswith("#"):
        return None
    lower = entry.lower()
    if lower.startswith("acestream://"):
        match = INFOHASH_RE.search(entry[len("acestream://"):])
        return match.group(0).lower() if match else None
    if lower.startswith(("http://", "https://")):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(entry).query)
        for key in ("id", "infohash", "content_id"):
            values = query.get(key)
            if values:
                match = INFOHASH_RE.search(values[0])
                if match:
                    return match.group(0).lower()
        return None
    if "/" not in entry:
        match = INFOHASH_RE.search(entry)
        if match:
            return match.group(0).lower()
    return None


def rewrite_playlist(text):
    """Rewrite every AceStream entry of an M3U payload to the local engine.

    Entries carry HOST_TOKEN instead of a fixed host; the HTTP handler
    replaces it per request with the host the client used, so the same
    playlist works from the LAN and from Tailscale at once.
    """
    template = "http://%s:%s/ace/getstream?id=%%s" % (HOST_TOKEN, PUBLIC_PORT)
    lines = []
    rewritten = 0
    for line in text.splitlines():
        infohash = extract_infohash(line)
        if infohash:
            lines.append(template % infohash)
            rewritten += 1
        else:
            lines.append(line)
    return "\n".join(lines) + "\n", rewritten


def candidate_urls(origin):
    """Translate an origin into the list of URLs to try, in order."""
    lower = origin.lower()
    if lower.startswith(("ipns://", "ipfs://")):
        scheme = "ipns" if lower.startswith("ipns://") else "ipfs"
        rest = origin.split("://", 1)[1]
        root, _, path = rest.partition("/")
        gateway_path = urllib.parse.quote(
            "/%s/%s/%s" % (scheme, root, path.lstrip("/")), safe="/"
        )
        return [gateway + gateway_path for gateway in [IPFS_GATEWAY] + IPFS_FALLBACK_GATEWAYS]
    if lower.startswith(("http://", "https://")):
        return [origin]
    return []


def fetch_playlist(urls):
    """Fetch the first URL that returns a valid #EXTM3U payload."""
    for url in urls:
        try:
            log.info("fetching %s", url)
            request = urllib.request.Request(
                url, headers={"User-Agent": "miniace/1.0"}
            )
            with OPENER.open(request, timeout=FETCH_TIMEOUT) as response:
                payload = response.read()
            text = payload.decode("utf-8-sig", errors="replace").lstrip()
            if not text.startswith("#EXTM3U"):
                raise ValueError("payload is not an M3U playlist")
            return text
        except Exception as exc:  # noqa: BLE001 - keep trying other gateways
            log.warning("fetch failed for %s: %s", url, exc)
    return None


def write_playlist(filename, text):
    """Atomically write a playlist file inside PLAYLISTS_DIR."""
    os.makedirs(PLAYLISTS_DIR, exist_ok=True)
    path = os.path.join(PLAYLISTS_DIR, filename)
    fd, tmp = tempfile.mkstemp(dir=PLAYLISTS_DIR, prefix=".tmp-", suffix=".m3u")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_sources():
    with open(SOURCES_FILE, encoding="utf-8") as handle:
        sources = json.load(handle)
    if not isinstance(sources, list):
        raise ValueError("%s must contain a JSON array" % SOURCES_FILE)
    normalized = []
    for source in sources:
        if not isinstance(source, dict):
            continue
        name = str(source.get("name") or source.get("nombre") or "").strip()
        origin = str(source.get("origin") or source.get("origen") or "").strip()
        if name and origin:
            normalized.append((name, origin))
        else:
            log.warning("skipping source without name/origin: %r", source)
    return normalized


def sync_once():
    sources = load_sources()
    if not sources:
        log.warning("no usable sources found in %s", SOURCES_FILE)
        return

    merged_header = None
    merged_entries = []
    for name, origin in sources:
        text = fetch_playlist(candidate_urls(origin))
        if text is None:
            log.error(
                "could not fetch playlist %r from %s; keeping the previous file",
                name,
                origin,
            )
            continue
        rewritten, count = rewrite_playlist(text)
        write_playlist("%s.m3u" % name, rewritten)
        log.info("synced %r: %d acestream channels rewritten", name, count)

        lines = rewritten.splitlines()
        header = lines[0] if lines and lines[0].startswith("#EXTM3U") else "#EXTM3U"
        body = lines[1:] if lines and lines[0].startswith("#EXTM3U") else lines
        if merged_header is None:
            merged_header = header
            merged_entries.extend(body)
        else:
            merged_entries.extend(body)

    if merged_header is not None:
        write_playlist("all.m3u", "\n".join([merged_header] + merged_entries) + "\n")
        log.info("merged playlist written to all.m3u")


def sync_loop():
    while not stop_event.is_set():
        try:
            sync_once()
        except Exception:  # noqa: BLE001 - the loop must survive bad cycles
            log.exception("unexpected error during sync")
        stop_event.wait(SYNC_INTERVAL)


class PlaylistHandler(SimpleHTTPRequestHandler):
    # Python maps .m3u to the HLS MIME type (application/vnd.apple.mpegurl),
    # which makes VLC treat the generated playlists as HLS manifests and
    # fail. audio/x-mpegurl is the classic playlist type VLC opens as a
    # channel list.
    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".m3u": "audio/x-mpegurl",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PLAYLISTS_DIR, **kwargs)

    def log_message(self, fmt, *args):
        log.debug("http %s", fmt % args)

    @staticmethod
    def _request_host(host_header):
        """Host used by the client, without port (IPv4/hostname only)."""
        return host_header.split(":", 1)[0].strip()

    def send_head(self):
        """Serve .m3u playlists with HOST_TOKEN replaced by the request host."""
        path = self.translate_path(self.path)
        if not path.endswith(".m3u") or not os.path.isfile(path):
            return super().send_head()
        with open(path, "rb") as handle:
            body = handle.read()
        host = self._request_host(self.headers.get("Host", ""))
        if host:
            body = body.replace(HOST_TOKEN.encode(), host.encode())
        self.send_response(200)
        self.send_header("Content-Type", self.extensions_map.get(".m3u", "audio/x-mpegurl"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Vary", "Host")
        self.end_headers()
        return io.BytesIO(body)


def main():
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    log.info(
        "playlists: serving %s on :%d, rewriting entries to "
        "http://<request-host>:%s/ace/getstream",
        PLAYLISTS_DIR,
        HTTP_PORT,
        PUBLIC_PORT,
    )
    log.info(
        "sync: sources=%s interval=%ds gateway=%s fallbacks=%s",
        SOURCES_FILE,
        SYNC_INTERVAL,
        IPFS_GATEWAY,
        ",".join(IPFS_FALLBACK_GATEWAYS) or "(none)",
    )

    threading.Thread(target=sync_loop, name="sync", daemon=True).start()

    server = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), PlaylistHandler)

    def _shutdown(signum, _frame):
        log.info("received signal %d, shutting down", signum)
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server.serve_forever()
    log.info("http server stopped")


if __name__ == "__main__":
    main()
