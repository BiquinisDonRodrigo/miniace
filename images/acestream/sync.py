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

A full cycle runs every SYNC_INTERVAL seconds; sources that fail are
retried (only them) every RETRY_INTERVAL seconds until the next full
cycle. all.m3u is always rebuilt from the latest <name>.m3u of every
configured source, so a temporarily down source keeps its last known
channels.
"""

import io
import json
import logging
import os
import re
import signal
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

SOURCES_FILE = os.environ.get("SOURCES_FILE", "/data/sources.json")
PLAYLISTS_DIR = os.environ.get("PLAYLISTS_DIR", "/data/playlists")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "3600"))
RETRY_INTERVAL = int(os.environ.get("RETRY_INTERVAL", "60"))
FETCH_TIMEOUT = int(os.environ.get("FETCH_TIMEOUT", "120"))
HOST_TOKEN = "__MINIACE_HOST__"
PUBLIC_PORT = (os.environ.get("PUBLIC_PORT") or "6878").strip()

IPFS_GATEWAY = os.environ.get("IPFS_GATEWAY", "http://kubo:48080").rstrip("/")
# ipfs.io, dweb.link and w3s.link were retired on 2026-09-21 (they answer
# 429/403, or redirect to the retired dweb.link). filebase.io is the only
# public fallback verified to serve both /ipfs/ and /ipns/ paths; any
# gateway added to this list must support /ipns/ resolution too.
IPFS_FALLBACK_GATEWAYS = [
    gateway.strip().rstrip("/")
    for gateway in os.environ.get(
        "IPFS_FALLBACK_GATEWAYS",
        "https://ipfs.filebase.io",
    ).split(",")
    if gateway.strip()
]

INFOHASH_RE = re.compile(r"[0-9a-fA-F]{40}")


class _RedirectHandler(urllib.request.HTTPRedirectHandler):
    """Extend urllib with 308 (Permanent Redirect) support.

    Python 3.10's redirect_request() only allows 301/302/303/307 for GET,
    so a 308 answer raises "HTTP Error 308" instead of being followed —
    and public IPFS gateways answer with 308. Map a 308 onto a 307 (same
    semantics: the method must be preserved) inside redirect_request(),
    and route http_error_308 through the standard 302 machinery.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if code == 308:
            code = 307
        return super().redirect_request(req, fp, code, msg, headers, newurl)

    http_error_308 = urllib.request.HTTPRedirectHandler.http_error_302


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


GATEWAY_PATH_RE = re.compile(r"^/(?:ipfs|ipns)/")
GATEWAY_SUBDOMAIN_RE = re.compile(r"^(.+?)\.(ipfs|ipns)\.")


def ipfs_gateways():
    """Gateways to try in order: the local Kubo node, then the fallbacks."""
    return [IPFS_GATEWAY] + IPFS_FALLBACK_GATEWAYS


def _gateway_path(origin):
    """Return the /ipfs/... or /ipns/... path embedded in a gateway URL.

    Understands the path form (https://gw/ipfs/<cid>/...) and the subdomain
    form (https://<root>.ipfs|ipns.<host>/...). IPNS subdomain labels are
    decoded back into the DNSLink name ("--" becomes "-", "-" becomes "."),
    so the same origin still resolves through another gateway — or through
    the local Kubo node — when the original gateway is down. Returns None
    for URLs that carry no gateway path.
    """
    parts = urllib.parse.urlsplit(origin)
    path = urllib.parse.unquote(parts.path or "")
    if GATEWAY_PATH_RE.match(path):
        return urllib.parse.quote(path, safe="/")
    match = GATEWAY_SUBDOMAIN_RE.match((parts.hostname or "").lower())
    if not match:
        return None
    root, scheme = match.groups()
    if scheme == "ipns":
        root = root.replace("--", "\0").replace("-", ".").replace("\0", "-")
    return urllib.parse.quote("/%s/%s%s" % (scheme, root, path), safe="/")


def candidate_urls(origin):
    """Translate an origin into the list of URLs to try, in order."""
    lower = origin.lower()
    if lower.startswith(("ipns://", "ipfs://")):
        scheme = "ipns" if lower.startswith("ipns://") else "ipfs"
        rest = origin.split("://", 1)[1]
        root, _, path = rest.partition("/")
        # Unquote first so an already-encoded path ("My%20List.m3u") is not
        # double-encoded ("My%2520List.m3u"); quote normalizes the rest.
        gateway_path = urllib.parse.quote(
            urllib.parse.unquote("/%s/%s/%s" % (scheme, root, path.lstrip("/"))),
            safe="/",
        )
        return [gateway + gateway_path for gateway in ipfs_gateways()]
    if lower.startswith(("http://", "https://")):
        urls = [origin]
        gateway_path = _gateway_path(origin)
        if gateway_path:
            for gateway in ipfs_gateways():
                url = gateway + gateway_path
                if url not in urls:
                    urls.append(url)
        return urls
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
    """Read and validate sources.json.

    Unusable entries are skipped with a warning: names containing "/" or a
    null byte (path traversal), names starting with "." (hidden files) and
    "all" (reserved for the merged playlist), plus duplicated names (the
    first one wins). Raises OSError/ValueError — so the sync loop retries
    soon — when the file is missing, unreadable, invalid JSON or yields no
    usable source at all.
    """
    with open(SOURCES_FILE, encoding="utf-8") as handle:
        sources = json.load(handle)
    if not isinstance(sources, list):
        raise ValueError("%s must contain a JSON array" % SOURCES_FILE)
    normalized = []
    seen = set()
    for source in sources:
        if not isinstance(source, dict):
            continue
        name = str(source.get("name") or source.get("nombre") or "").strip()
        origin = str(source.get("origin") or source.get("origen") or "").strip()
        if not name or not origin:
            log.warning("skipping source without name/origin: %r", source)
            continue
        if "/" in name or "\0" in name or name.startswith(".") or name == "all":
            log.warning("skipping source with unusable name %r", name)
            continue
        if name in seen:
            log.warning("skipping duplicated source name %r", name)
            continue
        seen.add(name)
        normalized.append((name, origin))
    if not normalized:
        raise ValueError("%s contains no usable source" % SOURCES_FILE)
    return normalized


def refresh_source(name, origin):
    """Fetch, rewrite and write one source playlist.

    Returns False when the fetch failed; the previous <name>.m3u is kept so
    the source's channels survive until the next successful fetch.
    """
    text = fetch_playlist(candidate_urls(origin))
    if text is None:
        log.error(
            "could not fetch playlist %r from %s; keeping the previous file",
            name,
            origin,
        )
        return False
    rewritten, count = rewrite_playlist(text)
    write_playlist("%s.m3u" % name, rewritten)
    log.info("synced %r: %d acestream channels rewritten", name, count)
    return True


def write_merged(sources):
    """Rebuild all.m3u from the latest <name>.m3u of every configured source.

    Sources without a file on disk yet (never fetched successfully) are
    skipped, so a source that failed this cycle keeps its previous channels
    in the merge, and a source removed from sources.json disappears. The
    first #EXTM3U header is kept. Returns True when all.m3u was written.
    """
    merged_header = None
    merged_entries = []
    for name, _origin in sources:
        path = os.path.join(PLAYLISTS_DIR, "%s.m3u" % name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        if not lines:
            continue
        if lines[0].startswith("#EXTM3U"):
            if merged_header is None:
                merged_header = lines[0]
            merged_entries.extend(lines[1:])
        else:
            if merged_header is None:
                merged_header = "#EXTM3U"
            merged_entries.extend(lines)
    if merged_header is None:
        return False
    write_playlist("all.m3u", "\n".join([merged_header] + merged_entries) + "\n")
    log.info("merged playlist written to all.m3u")
    return True


def sync_once(names=None):
    """Refresh the configured sources (only `names` when given).

    Every source is refreshed independently: a source that fails — or
    raises — is logged and reported without aborting the others. all.m3u is
    always rebuilt from every configured source's file on disk. Returns the
    set of source names that could not be refreshed.
    """
    all_sources = load_sources()
    sources = all_sources
    if names is not None:
        wanted = set(names)
        sources = [source for source in all_sources if source[0] in wanted]
    failed = set()
    for name, origin in sources:
        try:
            if not refresh_source(name, origin):
                failed.add(name)
        except Exception:  # noqa: BLE001 - one bad source must not sink the rest
            log.exception("unexpected error while syncing source %r", name)
            failed.add(name)
    write_merged(all_sources)
    return failed


def _sync_cycle(names=None):
    """Run one sync cycle and return the set of failed sources, or None
    when the cycle could not run at all (missing/invalid sources.json,
    disk error, ...)."""
    try:
        return sync_once(names=names)
    except (OSError, ValueError) as exc:
        # Missing sources.json or invalid JSON (JSONDecodeError is a
        # ValueError) or a disk error: the file can be fixed or created
        # live, so retry the whole cycle soon.
        log.error("sync cycle failed: %s; retrying in %ds", exc, RETRY_INTERVAL)
    except Exception:  # noqa: BLE001 - the loop must survive bad cycles
        log.exception(
            "unexpected error during sync; retrying in %ds", RETRY_INTERVAL
        )
    return None


def _log_not_refreshed(failed):
    log.warning(
        "sync: %d source(s) not refreshed (%s); retrying in %ds",
        len(failed),
        ", ".join(sorted(failed)),
        RETRY_INTERVAL,
    )


def sync_loop():
    # A full cycle runs every SYNC_INTERVAL. Sources that fail are retried
    # — only them — every RETRY_INTERVAL until the next full cycle, so a
    # cold start (container up before gluetun has its DNS/VPN ready, Kubo
    # resolving IPNS for the first time, a dead public gateway) recovers in
    # minutes without re-hammering sources that are already healthy. A
    # cycle that cannot run at all retries the whole cycle after
    # RETRY_INTERVAL.
    while not stop_event.is_set():
        next_full = time.monotonic() + SYNC_INTERVAL
        failed = _sync_cycle()
        if failed is None:
            stop_event.wait(RETRY_INTERVAL)
            continue
        if failed:
            _log_not_refreshed(failed)
        while failed and not stop_event.is_set():
            delay = min(RETRY_INTERVAL, next_full - time.monotonic())
            if delay <= 0:
                break
            if stop_event.wait(delay):
                break
            failed = _sync_cycle(names=sorted(failed))
            if failed is None or not failed:
                break
            _log_not_refreshed(failed)
        if failed is None:
            stop_event.wait(RETRY_INTERVAL)
        elif not stop_event.is_set():
            stop_event.wait(max(next_full - time.monotonic(), 0.0))


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
