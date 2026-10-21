# syntax=docker/dockerfile:1
# miniace engine image: outpace + Gluetun port-forward supervision
# + IPNS/IPFS playlist sync and HTTP playlist server, in a single container.
#
# outpace is a from-scratch Rust implementation of the public AceStream live
# path (AGPL-3.0-or-later): https://github.com/jamezrin/outpace
# The static binary and its licence are copied from the official multi-arch
# image pinned below (v0.5.0); the repository does not vendor engine blobs.
# See NOTICE and the legal section of README.md.
FROM ghcr.io/jamezrin/outpace@sha256:c15f70186cc797222e7feed2a697c40d2498849b2ef11c4d3c6fe6f0d51e1624 AS outpace

FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    API_PORT=6878 \
    OUTPACE_DATA_DIR=/acestream/outpace \
    GLUETUN_CONTROL_BASE=http://127.0.0.1:8001 \
    GLUETUN_PORT_FILE=/tmp/gluetun/forwarded_port \
    PORT_WATCH_INTERVAL_S=10

# The python base already ships ca-certificates; curl and ss are the only
# runtime additions.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl iproute2 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=outpace /usr/local/bin/outpace /opt/miniace/outpace
COPY --from=outpace /usr/share/doc/outpace/LICENSE /usr/share/doc/outpace/LICENSE
COPY NOTICE /usr/share/doc/outpace/NOTICE

COPY entrypoint.sh outpace.sh sync.py /opt/miniace/
RUN chmod +x /opt/miniace/entrypoint.sh /opt/miniace/outpace.sh

# 6878: engine HTTP API. 8080: playlist HTTP server.
EXPOSE 6878 8080

# The playlist server is the always-on foreground process; the engine itself
# may legitimately be down while waiting for a forwarded VPN port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1

ENTRYPOINT ["/opt/miniace/entrypoint.sh"]
