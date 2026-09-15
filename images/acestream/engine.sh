# Shared AceStream engine launch + Gluetun/VPN port-forward logic.
#
# Sourced by entrypoint.sh. This file MUST ONLY define variables and
# functions: it has no side effects when sourced, so the caller decides
# what to run and in which order (engine_init -> start_engine & ->
# port_watch_loop &).
#
# Hard requirement: the engine ONLY ever binds the P2P port announced by
# the VPN provider (ProtonVPN NAT-PMP, negotiated by Gluetun). There is
# NO fallback to a static port such as 8621: while no forwarded port is
# available the engine simply does not start.

STATE_DIR="${STATE_DIR:-/tmp/miniace}"
GLUETUN_P2P_PORT_FILE="$STATE_DIR/gluetun_p2p_port"
ACTIVE_P2P_PORT_FILE="$STATE_DIR/active_p2p_port"

# Gluetun HTTP control server (HTTP_CONTROL_SERVER_ADDRESS=:8001 in the
# gluetun service). The current route is /v1/portforward; /v1/port_forwarded
# is also probed for compatibility with older Gluetun versions.
GLUETUN_CONTROL_BASE="${GLUETUN_CONTROL_BASE:-http://127.0.0.1:8001}"
GLUETUN_PORT_FILE="${GLUETUN_PORT_FILE:-/tmp/gluetun/forwarded_port}"
PORT_WATCH_INTERVAL_S="${PORT_WATCH_INTERVAL_S:-45}"

ENGINE_HOME="${ENGINE_HOME:-/opt/acestream}"
ENGINE_STATE_DIR="${ENGINE_STATE_DIR:-/acestream/state}"
ENGINE_CACHE_DIR="${ENGINE_CACHE_DIR:-/acestream/cache}"
ACESTREAM_CACHE_LIMIT_GB="${ACESTREAM_CACHE_LIMIT_GB:-5}"
API_PORT="${ACESTREAM_HTTP_PORT:-6878}"

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

# Echo the port ProtonVPN announced through Gluetun, or nothing.
# Resolution order:
#   1. Gluetun control API GET /v1/portforward ({"ports":[...],"port":N})
#   2. Legacy control API route /v1/port_forwarded
#   3. The status file Gluetun rewrites on every port change
query_gluetun_port() {
  local port="" path fp
  for path in /v1/portforward /v1/port_forwarded; do
    port=$(curl -fsS --max-time 3 "$GLUETUN_CONTROL_BASE$path" 2>/dev/null \
      | sed -nE 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]{1,5}).*/\1/p' | head -n1)
    is_valid_port "$port" && break
    port=""
  done
  if ! is_valid_port "$port" && [[ -s "$GLUETUN_PORT_FILE" ]]; then
    fp=$(<"$GLUETUN_PORT_FILE")
    if is_valid_port "$fp"; then
      port="$fp"
    fi
  fi
  if is_valid_port "$port"; then
    printf '%s\n' "$port" > "$GLUETUN_P2P_PORT_FILE" 2>/dev/null || true
    printf '%s\n' "$port"
  fi
}

# Probe the AceStream HTTP API: returns 0 when an engine daemon is alive.
engine_api_alive() {
  curl -fsS --max-time 3 \
    "http://127.0.0.1:${API_PORT}/webui/api/service?method=get_version" \
    >/dev/null 2>&1
}

# PIDs of running acestreamengine processes, found through /proc because
# the image ships no ps/pgrep. stderr is silenced before opening
# $d/cmdline: PIDs can vanish between the glob and the read.
engine_pids() {
  local d pid
  for d in /proc/[0-9]*; do
    [[ -r "$d/cmdline" ]] || continue
    pid=${d#/proc/}
    case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in
      *acestreamengine*) printf '%s\n' "$pid" ;;
    esac
  done
}

stop_engine() {
  local pid i
  for pid in $(engine_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    engine_api_alive || return 0
    sleep 1
  done
  for pid in $(engine_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Best-effort cleanup of daemons left over from a previous run: they keep
# holding the P2P port and wedge fresh starts.
sweep_engine_leftovers() {
  local pid
  for pid in $(engine_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(engine_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Persistent state + disk cache flags. A disk cache gives the swarm upload
# reciprocity (better peers); ACESTREAM_CACHE_LIMIT_GB=0 disables it.
build_engine_flags() {
  local flags="--state-dir=$ENGINE_STATE_DIR"
  if [[ "$ACESTREAM_CACHE_LIMIT_GB" =~ ^[0-9]+$ ]] && (( ACESTREAM_CACHE_LIMIT_GB > 0 )); then
    flags="$flags --cache-dir=$ENGINE_CACHE_DIR --cache-limit=$ACESTREAM_CACHE_LIMIT_GB"
  fi
  printf '%s' "$flags"
}

# Engine supervisor.
#
# The start-engine launcher daemonizes: it forks the real daemon and exits
# a few seconds later, so the loop supervises by probing the HTTP API
# instead of trusting the launcher PID. The forwarded port is re-resolved
# on every spawn, and restarts caused by a port rotation respawn
# immediately; only real crashes back off exponentially (3 -> 60 s).
#
# NOTE on flag spelling: the engine parses value flags in the
# --flag=value form (see Plugin/BackgroundProcess.py in the engine
# distribution), so --http-port and --port below always use "=".
#   --http-port : HTTP API port (default 6878)
#   --port      : P2P session port (default 8621) <- bound to the
#                 Gluetun forwarded port
#   --log-file  : second log sink in the persisted state dir (rotation
#                 is fixed by the engine at 10MB + 1 backup; --log-stdout
#                 above keeps docker compose logs working)
#   --vod-buffer: VOD buffer in seconds. Options like --live-buffer or
#                 --live-cache-type circulate in forums but are NOT
#                 recognized by engine 3.2.11, which silently drops
#                 unknown flags; this is the supported equivalent.
start_engine() {
  local backoff=3
  sweep_engine_leftovers
  while true; do
    if engine_api_alive; then
      sleep 5
      continue
    fi
    local p2p
    p2p=$(query_gluetun_port)
    if ! is_valid_port "$p2p"; then
      echo "engine: no Gluetun forwarded port available yet; waiting (the engine only binds the announced P2P port)" >&2
      sleep 5
      continue
    fi
    printf '%s\n' "$p2p" > "$ACTIVE_P2P_PORT_FILE" 2>/dev/null || true
    local engine_flags
    engine_flags=$(build_engine_flags)
    echo "engine: starting AceStream (HTTP API on $API_PORT, P2P on forwarded port $p2p)"
    # shellcheck disable=SC2086
    "$ENGINE_HOME/start-engine" \
      --client-console \
      --bind-all \
      --disable-sentry \
      --log-stdout \
      --log-stdout-level=info \
      --log-file="$ENGINE_STATE_DIR/acestream.log" \
      --vod-buffer=30 \
      --http-port="$API_PORT" \
      --port="$p2p" \
      $engine_flags 2>&1 &
    local pid=$!
    wait "$pid" 2>/dev/null || true
    sleep 2
    if engine_api_alive; then
      backoff=3
      continue
    fi
    local latest
    latest=$(query_gluetun_port)
    if is_valid_port "$latest" && [[ "$latest" != "$p2p" ]]; then
      echo "engine: forwarded port rotated underneath us ($p2p -> $latest); respawning immediately" >&2
      backoff=3
      continue
    fi
    backoff=$(( backoff * 2 ))
    if (( backoff > 60 )); then backoff=60; fi
    echo "engine: exited and the API is down; retrying in ${backoff}s..." >&2
    sleep "$backoff"
  done
}

# Port-forward watcher: ProtonVPN rotates the forwarded port on reconnect.
# When it changes, stop the engine so the supervisor respawns it bound to
# the new port. Streams in flight are interrupted for a few seconds.
port_watch_loop() {
  while true; do
    sleep "$PORT_WATCH_INTERVAL_S"
    local gluetun_port active_port
    gluetun_port=$(query_gluetun_port)
    [[ -z "$gluetun_port" ]] && continue
    active_port=""
    [[ -r "$ACTIVE_P2P_PORT_FILE" ]] && active_port=$(<"$ACTIVE_P2P_PORT_FILE")
    if [[ -n "$active_port" && "$gluetun_port" != "$active_port" ]] && engine_api_alive; then
      echo "engine: Gluetun forwarded port changed ($active_port -> $gluetun_port); restarting engine to rebind" >&2
      stop_engine
      rm -f "$ACTIVE_P2P_PORT_FILE" 2>/dev/null || true
    fi
  done
}

engine_init() {
  mkdir -p "$STATE_DIR" "$ENGINE_STATE_DIR" "$ENGINE_CACHE_DIR" 2>/dev/null || true
  echo "engine: state dir $ENGINE_STATE_DIR, cache dir $ENGINE_CACHE_DIR (limit ${ACESTREAM_CACHE_LIMIT_GB}GB)"
  if ! curl -fsS --max-time 2 "$GLUETUN_CONTROL_BASE/v1/portforward" >/dev/null 2>&1 \
     && [[ ! -s "$GLUETUN_PORT_FILE" ]]; then
    echo "engine: WARNING: Gluetun control server ($GLUETUN_CONTROL_BASE) is not reachable yet and $GLUETUN_PORT_FILE is empty; the engine will wait for a forwarded port" >&2
  fi
}
