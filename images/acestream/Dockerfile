# syntax=docker/dockerfile:1
# miniace/acestream: AceStream 3.2.11 engine + Gluetun port-forward supervision
# + IPFS/IPNS playlist sync and HTTP playlist server, in a single container.
FROM python:3.10-slim

ARG ACESTREAM_URL=https://download.acestream.media/linux/acestream_3.2.11_ubuntu_22.04_x86_64_py3.10.tar.gz
ARG ACESTREAM_SHA256=9b6bbd76a55e5a434641afae3b9cf8e6154ce1cf392152ec3aed5ac265432b2e

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    API_PORT=6878 \
    ENGINE_HOME=/opt/acestream \
    ENGINE_STATE_DIR=/acestream/state \
    ENGINE_CACHE_DIR=/acestream/cache \
    ACESTREAM_CACHE_LIMIT_GB=5 \
    ACESTREAM_MAX_CONNECTIONS=2000 \
    ACESTREAM_MAX_PEERS_LIMIT=500 \
    ACESTREAM_STARTUP_MAX_PEERS=100 \
    ACESTREAM_STARTUP_UPLOAD_SLOTS=50 \
    ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT=0 \
    ACESTREAM_UPLOAD_LIMIT=0 \
    ACESTREAM_DOWNLOAD_LIMIT=0 \
    ACESTREAM_FIX_UPLOAD_SLOTS=1 \
    ACESTREAM_LIVE_CACHE_TYPE=auto \
    ACESTREAM_VOD_CACHE_TYPE=auto \
    ACESTREAM_VOD_BUFFER=30 \
    ACESTREAM_LOG_STDOUT_LEVEL=info \
    ACESTREAM_LOG_MAX_SIZE=10485760 \
    ACESTREAM_LOG_BACKUP_COUNT=1 \
    GLUETUN_CONTROL_BASE=http://127.0.0.1:8001 \
    GLUETUN_PORT_FILE=/tmp/gluetun/forwarded_port \
    PORT_WATCH_INTERVAL_S=10

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl iproute2 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/acestream

# Download and verify the official engine tarball, then install its Python
# dependencies (pinned copies live in requirements.txt in this build context).
RUN curl -fsSL "$ACESTREAM_URL" -o /tmp/acestream.tgz && \
    echo "$ACESTREAM_SHA256  /tmp/acestream.tgz" | sha256sum -c - && \
    tar -xzf /tmp/acestream.tgz -C /opt/acestream && \
    rm /tmp/acestream.tgz

COPY requirements.txt /tmp/miniace-requirements.txt
RUN pip install --no-cache-dir -r /tmp/miniace-requirements.txt && \
    rm /tmp/miniace-requirements.txt

COPY engine.sh entrypoint.sh configure_engine.py sync.py /opt/miniace/
RUN chmod +x /opt/miniace/entrypoint.sh /opt/miniace/engine.sh

# 6878: AceStream engine HTTP API. 8080: playlist HTTP server.
EXPOSE 6878 8080

# The playlist server is the always-on foreground process; the engine itself
# may legitimately be down while waiting for a forwarded VPN port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1

ENTRYPOINT ["/opt/miniace/entrypoint.sh"]
