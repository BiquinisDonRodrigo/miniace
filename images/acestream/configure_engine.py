#!/usr/bin/env python3
"""Apply client settings through AceStream's local authenticated API.

Exit 10 requests a restart after changing persisted settings. In Desktop
3.2.11 the client replaces some bootstrap CLI preferences with player config;
in particular, max_connections is only loaded into native prefs at startup.
"""

import argparse
import json
import sys
from pathlib import Path
from urllib.request import ProxyHandler, Request, build_opener


def build_wanted(args):
    """Settings miniace manages. Empty optional values are not synced."""
    wanted = {
        "max_connections": args.max_connections,
        "max_peers": args.max_peers,
        "max_upload_slots": args.max_upload_slots,
        "auto_slots": args.auto_slots == 1,
        "upload_limit": args.upload_limit,
        "download_limit": args.download_limit,
        "cache_dir": args.cache_dir,
        "memory_cache_limit": args.memory_cache_limit,
        "live_cache_type": args.live_cache_type,
        "vod_cache_type": args.vod_cache_type,
        "vod_buffer": args.vod_buffer,
    }
    if args.cache_limit_gb:
        wanted["disk_cache_limit"] = args.cache_limit_gb * 1024**3
    else:
        del wanted["disk_cache_limit"]
    for key in ("max_upload_slots", "memory_cache_limit"):
        if wanted[key] == "":
            del wanted[key]
    return {key: int(value) if isinstance(value, str) and value.isdigit() else value
            for key, value in wanted.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-file", type=Path, required=True)
    parser.add_argument("--api-port", type=int, required=True)
    parser.add_argument("--max-connections", type=int, required=True)
    parser.add_argument("--max-peers", type=int, required=True)
    parser.add_argument("--max-upload-slots", default="")
    parser.add_argument("--upload-limit", type=int, required=True)
    parser.add_argument("--download-limit", type=int, required=True)
    parser.add_argument("--auto-slots", type=int, choices=(0, 1), required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--cache-limit-gb", type=int, required=True)
    parser.add_argument("--memory-cache-limit", default="")
    parser.add_argument("--live-cache-type", choices=("disk", "memory"), required=True)
    parser.add_argument("--vod-cache-type", choices=("disk", "memory"), required=True)
    parser.add_argument("--vod-buffer", type=int, required=True)
    args = parser.parse_args()
    wanted = build_wanted(args)

    try:
        runtime = json.loads(args.runtime_file.read_text())
        token = runtime["access_token"]
        if not isinstance(token, str) or not token:
            raise ValueError("missing engine access token")
        headers = {"x-api-key": token, "Accept": "application/json"}
        url = f"http://127.0.0.1:{args.api_port}/api/v1/settings"
        opener = build_opener(ProxyHandler({}))

        def get_settings():
            with opener.open(Request(url, headers=headers), timeout=5) as response:
                settings = json.load(response)
            if not isinstance(settings, dict):
                raise ValueError("invalid engine settings response")
            return settings

        current = get_settings()
        changes = {key: value for key, value in wanted.items() if current.get(key) != value}
        if changes:
            request = Request(
                url,
                data=json.dumps(changes).encode("utf-8"),
                headers={**headers, "Content-Type": "application/json"},
                method="PATCH",
            )
            with opener.open(request, timeout=5):
                pass
            current = get_settings()
            if any(current.get(key) != value for key, value in wanted.items()):
                raise ValueError("engine did not accept the requested settings")
            print(f"engine: saved client settings: {', '.join(changes)}", flush=True)
            return 10
        print(
            f"engine: client settings verified (connections={args.max_connections}, "
            f"startup peers={args.max_peers}, upload limit={args.upload_limit}Kb/s, "
            f"adaptive slots={args.auto_slots})",
            flush=True,
        )
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"engine: failed to configure client settings: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
