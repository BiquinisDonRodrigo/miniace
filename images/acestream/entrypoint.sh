#!/usr/bin/env bash
# miniace/acestream container entrypoint.
#
# Shares the gluetun network namespace (network_mode: service:gluetun):
#   - resolves the P2P port announced by ProtonVPN through Gluetun and
#     keeps the engine bound to it (see engine.sh)
#   - runs the IPNS->M3U playlist sync and the playlist HTTP server
set -uo pipefail

source /opt/miniace/engine.sh

engine_init

start_engine &
port_watch_loop &

SYNC_PID=""

shutdown() {
  echo "entrypoint: shutting down"
  stop_engine || true
  if [[ -n "$SYNC_PID" ]] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill -TERM "$SYNC_PID" 2>/dev/null || true
  fi
  wait "$SYNC_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

mkdir -p /data/playlists

python3 -u /opt/miniace/sync.py &
SYNC_PID=$!
wait "$SYNC_PID"
shutdown
