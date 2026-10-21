# Shared outpace engine launch + Gluetun/VPN port-forward logic.
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
#
# outpace is a from-scratch Rust implementation of the public AceStream
# live path (AGPL-3.0-or-later). It exposes the same /ace/getstream
# contract miniace clients use, behind OUTPACE_EXPERIMENTAL_ACE_COMPAT=1.

STATE_DIR="${STATE_DIR:-/tmp/miniace}"
GLUETUN_P2P_PORT_FILE="$STATE_DIR/gluetun_p2p_port"
ACTIVE_P2P_PORT_FILE="$STATE_DIR/active_p2p_port"

# Gluetun HTTP control server (HTTP_CONTROL_SERVER_ADDRESS=:8001 in the
# gluetun service). The port is published at GET /v1/portforward as
# {"ports":[...],"port":N}; port 0 means no forwarded port right now.
GLUETUN_CONTROL_BASE="${GLUETUN_CONTROL_BASE:-http://127.0.0.1:8001}"
GLUETUN_PORT_FILE="${GLUETUN_PORT_FILE:-/tmp/gluetun/forwarded_port}"
PORT_WATCH_INTERVAL_S="${PORT_WATCH_INTERVAL_S:-10}"

OUTPACE_BIN="${OUTPACE_BIN:-/opt/miniace/outpace}"
API_PORT="${API_PORT:-6878}"
OUTPACE_DATA_DIR="${OUTPACE_DATA_DIR:-/acestream/outpace}"
OUTPACE_CACHE_TYPE="${OUTPACE_CACHE_TYPE:-memory}"
OUTPACE_CACHE_DIR="${OUTPACE_CACHE_DIR:-$OUTPACE_DATA_DIR/cache}"
OUTPACE_SEED_STORE_BYTES="${OUTPACE_SEED_STORE_BYTES:-134217728}"
OUTPACE_SEED_RETENTION_SECS="${OUTPACE_SEED_RETENTION_SECS:-45}"
OUTPACE_MAX_INBOUND="${OUTPACE_MAX_INBOUND:-64}"
OUTPACE_MAX_ACTIVE_UPSTREAMS="${OUTPACE_MAX_ACTIVE_UPSTREAMS:-4}"
OUTPACE_MAX_PARALLEL_CONNECT="${OUTPACE_MAX_PARALLEL_CONNECT:-12}"
OUTPACE_SESSION_BUFFER="${OUTPACE_SESSION_BUFFER:-256}"
OUTPACE_PREBUFFER_BYTES="${OUTPACE_PREBUFFER_BYTES:-134217728}"
OUTPACE_ENABLE_INBOUND="${OUTPACE_ENABLE_INBOUND:-1}"
OUTPACE_ENABLE_SEEDING="${OUTPACE_ENABLE_SEEDING:-1}"

# Check before spawning either background loop. Canonical decimal integers
# avoid Bash's octal interpretation and arithmetic expansion of user input.
validate_outpace_config() {
  local name value
  for name in OUTPACE_SEED_STORE_BYTES OUTPACE_MAX_INBOUND \
    OUTPACE_MAX_ACTIVE_UPSTREAMS OUTPACE_MAX_PARALLEL_CONNECT \
    OUTPACE_SESSION_BUFFER OUTPACE_PREBUFFER_BYTES; do
    value=${!name}
    if [[ ! "$value" =~ ^[1-9][0-9]{0,19}$ ]]; then
      echo "engine: ERROR: $name must be a positive decimal integer, got '$value'" >&2
      return 1
    fi
  done
  if (( OUTPACE_PREBUFFER_BYTES < 188 )); then
    echo "engine: ERROR: OUTPACE_PREBUFFER_BYTES must be at least 188 bytes" >&2
    return 1
  fi
  value=$OUTPACE_SEED_RETENTION_SECS
  if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,19})$ ]]; then
    echo "engine: ERROR: OUTPACE_SEED_RETENTION_SECS must be a non-negative decimal integer, got '$value'" >&2
    return 1
  fi
  for name in OUTPACE_ENABLE_INBOUND OUTPACE_ENABLE_SEEDING; do
    value=${!name}
    if [[ "$value" != 0 && "$value" != 1 ]]; then
      echo "engine: ERROR: $name must be 0 or 1" >&2
      return 1
    fi
  done
  if [[ ! "$OUTPACE_CACHE_TYPE" =~ ^(memory|disk)$ ]]; then
    echo "engine: ERROR: OUTPACE_CACHE_TYPE must be memory or disk, got '$OUTPACE_CACHE_TYPE'" >&2
    return 1
  fi
  if [[ ! "$API_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( API_PORT > 65535 )); then
    echo "engine: ERROR: API_PORT must be a valid TCP port, got '$API_PORT'" >&2
    return 1
  fi
  if [[ ! "$PORT_WATCH_INTERVAL_S" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "engine: ERROR: PORT_WATCH_INTERVAL_S must be a positive decimal integer, got '$PORT_WATCH_INTERVAL_S'" >&2
    return 1
  fi
  if [[ ! -x "$OUTPACE_BIN" ]]; then
    echo "engine: ERROR: outpace binary not found or not executable at $OUTPACE_BIN" >&2
    return 1
  fi
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

# Echo the port ProtonVPN announced through Gluetun, or nothing.
# Resolution order:
#   1. Gluetun control API GET /v1/portforward ({"ports":[...],"port":N});
#      port 0 or a failed request counts as "not available"
#   2. The status file Gluetun rewrites on every port change
query_gluetun_port() {
  local port fp
  port=$(curl -fsS --max-time 3 "$GLUETUN_CONTROL_BASE/v1/portforward" 2>/dev/null \
    | sed -nE 's/.*"port"[[:space:]]*:[[:space:]]*([0-9]{1,5}).*/\1/p' | head -n1)
  if ! is_valid_port "$port"; then
    port=""
    if [[ -s "$GLUETUN_PORT_FILE" ]]; then
      fp=$(<"$GLUETUN_PORT_FILE")
      if is_valid_port "$fp"; then
        port="$fp"
      fi
    fi
  fi
  if is_valid_port "$port"; then
    printf '%s\n' "$port" > "$GLUETUN_P2P_PORT_FILE" 2>/dev/null || true
    printf '%s\n' "$port"
  fi
}

# Probe the outpace HTTP API: returns 0 when the daemon is alive.
outpace_alive() {
  curl -fsS --max-time 3 "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1
}

# PIDs of running outpace processes, found through /proc because the image
# ships no ps/pgrep. stderr is silenced before opening $d/cmdline: PIDs can
# vanish between the glob and the read.
outpace_pids() {
  local d pid
  for d in /proc/[0-9]*; do
    [[ -r "$d/cmdline" ]] || continue
    pid=${d#/proc/}
    case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)" in
      *"/opt/miniace/outpace serve"*) printf '%s\n' "$pid" ;;
    esac
  done
}

stop_engine() {
  local pid i
  for pid in $(outpace_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for (( i=0; i<10; i++ )); do
    [[ -z "$(outpace_pids)" ]] && return 0
    sleep 1
  done
  for pid in $(outpace_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Best-effort cleanup of daemons left over from a previous run: they keep
# holding the P2P port and wedge fresh starts.
sweep_engine_leftovers() {
  local pid
  for pid in $(outpace_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(outpace_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# Spawn outpace as the supervisor's background child. The forwarded port is
# resolved by the supervisor on every spawn. Compatibility routes are
# required by the M3U contract, and Gluetun (not outpace) owns the NAT-PMP
# mapping.
start_outpace() {
  local p2p=$1
  OUTPACE_BIND="0.0.0.0:${API_PORT}" \
  OUTPACE_PEER_LISTEN="0.0.0.0:${p2p}" \
  OUTPACE_RTMP_BIND="127.0.0.1:1935" \
  OUTPACE_DATA_DIR="$OUTPACE_DATA_DIR" \
  OUTPACE_CACHE_TYPE="$OUTPACE_CACHE_TYPE" \
  OUTPACE_CACHE_DIR="$OUTPACE_CACHE_DIR" \
  OUTPACE_SEED_STORE_BYTES="$OUTPACE_SEED_STORE_BYTES" \
  OUTPACE_SEED_RETENTION_SECS="$OUTPACE_SEED_RETENTION_SECS" \
  OUTPACE_MAX_INBOUND="$OUTPACE_MAX_INBOUND" \
  OUTPACE_MAX_ACTIVE_UPSTREAMS="$OUTPACE_MAX_ACTIVE_UPSTREAMS" \
  OUTPACE_MAX_PARALLEL_CONNECT="$OUTPACE_MAX_PARALLEL_CONNECT" \
  OUTPACE_SESSION_BUFFER="$OUTPACE_SESSION_BUFFER" \
  OUTPACE_PREBUFFER_BYTES="$OUTPACE_PREBUFFER_BYTES" \
  OUTPACE_ENABLE_INBOUND="$OUTPACE_ENABLE_INBOUND" \
  OUTPACE_ENABLE_SEEDING="$OUTPACE_ENABLE_SEEDING" \
  OUTPACE_ENABLE_PORT_MAPPING=0 \
  OUTPACE_EXPERIMENTAL_ACE_COMPAT=1 \
  "$OUTPACE_BIN" serve 2>&1 &
}

# Engine supervisor.
#
# The API probe is independent of the launcher PID: outpace can crash while
# the process table still shows the shell wrapper. The forwarded port is
# re-resolved on every spawn; port rotations respawn immediately, crashes
# back off (3 -> 60 s).
start_engine() {
  local backoff=3 running=0 active_p2p="" pid ready deadline latest
  sweep_engine_leftovers
  while true; do
    if outpace_alive; then
      running=1
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
    if (( running )) && [[ "$p2p" == "$active_p2p" ]]; then
      running=0
      stop_engine
      backoff=$(( backoff * 2 ))
      if (( backoff > 60 )); then backoff=60; fi
      echo "engine: outpace stopped responding; retrying in ${backoff}s..." >&2
      sleep "$backoff"
      continue
    fi
    running=0
    stop_engine
    active_p2p=$p2p
    printf '%s\n' "$p2p" > "$ACTIVE_P2P_PORT_FILE" 2>/dev/null || true
    echo "engine: starting outpace (HTTP API on $API_PORT, P2P on forwarded port $p2p)"
    start_outpace "$p2p"
    pid=$!
    ready=0
    deadline=$(( SECONDS + 60 ))
    while (( SECONDS < deadline )); do
      if outpace_alive; then
        ready=1
        break
      fi
      if ! kill -0 "$pid" 2>/dev/null && [[ -z "$(outpace_pids)" ]]; then
        break
      fi
      sleep 1
    done
    if (( ready )); then
      running=1
      backoff=3
      continue
    fi
    stop_engine
    wait "$pid" 2>/dev/null || true
    latest=$(query_gluetun_port)
    if is_valid_port "$latest" && [[ "$latest" != "$p2p" ]]; then
      echo "engine: forwarded port rotated underneath us ($p2p -> $latest); respawning immediately" >&2
      backoff=3
      continue
    fi
    backoff=$(( backoff * 2 ))
    if (( backoff > 60 )); then backoff=60; fi
    echo "engine: outpace failed to become ready; retrying in ${backoff}s..." >&2
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
    if [[ -n "$active_port" && "$gluetun_port" != "$active_port" ]] && outpace_alive; then
      echo "engine: Gluetun forwarded port changed ($active_port -> $gluetun_port); restarting engine to rebind" >&2
      stop_engine
      rm -f "$ACTIVE_P2P_PORT_FILE" 2>/dev/null || true
    fi
  done
}

engine_init() {
  validate_outpace_config || return 1
  mkdir -p "$STATE_DIR" "$OUTPACE_DATA_DIR" 2>/dev/null || true
  if [[ "$OUTPACE_CACHE_TYPE" == disk ]]; then
    mkdir -p "$OUTPACE_CACHE_DIR" 2>/dev/null || true
  fi
  echo "engine: outpace data dir $OUTPACE_DATA_DIR (cache=$OUTPACE_CACHE_TYPE)"
  echo "engine: P2P profile: inbound=$OUTPACE_ENABLE_INBOUND seeding=$OUTPACE_ENABLE_SEEDING max-inbound=$OUTPACE_MAX_INBOUND upstreams=$OUTPACE_MAX_ACTIVE_UPSTREAMS parallel-connect=$OUTPACE_MAX_PARALLEL_CONNECT seed-store=$OUTPACE_SEED_STORE_BYTES bytes retention=${OUTPACE_SEED_RETENTION_SECS}s"
  if ! curl -fsS --max-time 2 "$GLUETUN_CONTROL_BASE/v1/portforward" >/dev/null 2>&1 \
     && [[ ! -s "$GLUETUN_PORT_FILE" ]]; then
    echo "engine: WARNING: Gluetun control server ($GLUETUN_CONTROL_BASE) is not reachable yet and $GLUETUN_PORT_FILE is empty; the engine will wait for a forwarded port" >&2
  fi
}
