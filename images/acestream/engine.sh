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
PORT_WATCH_INTERVAL_S="${PORT_WATCH_INTERVAL_S:-10}"

ENGINE_HOME="${ENGINE_HOME:-/opt/acestream}"
ENGINE_STATE_DIR="${ENGINE_STATE_DIR:-/acestream/state}"
ENGINE_CACHE_DIR="${ENGINE_CACHE_DIR:-/acestream/cache}"
ACESTREAM_CACHE_LIMIT_GB="${ACESTREAM_CACHE_LIMIT_GB:-5}"
ACESTREAM_MAX_CONNECTIONS="${ACESTREAM_MAX_CONNECTIONS:-2000}"
ACESTREAM_MAX_PEERS_LIMIT="${ACESTREAM_MAX_PEERS_LIMIT:-500}"
ACESTREAM_STARTUP_MAX_PEERS="${ACESTREAM_STARTUP_MAX_PEERS:-100}"
ACESTREAM_STARTUP_UPLOAD_SLOTS="${ACESTREAM_STARTUP_UPLOAD_SLOTS:-50}"
ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT="${ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT:-0}"
# Optional engine options: empty keeps the engine's factory default (the
# matching CLI flag is omitted). Units: Kb/s for limits, bytes for sizes.
ACESTREAM_UPLOAD_LIMIT="${ACESTREAM_UPLOAD_LIMIT:-0}"
ACESTREAM_DOWNLOAD_LIMIT="${ACESTREAM_DOWNLOAD_LIMIT:-0}"
ACESTREAM_MAX_UPLOAD_SLOTS="${ACESTREAM_MAX_UPLOAD_SLOTS:-}"
ACESTREAM_MIN_UPLOAD_SLOTS="${ACESTREAM_MIN_UPLOAD_SLOTS:-}"
ACESTREAM_FIX_UPLOAD_SLOTS="${ACESTREAM_FIX_UPLOAD_SLOTS:-1}"
ACESTREAM_MAX_TIMESHIFT_PEERS="${ACESTREAM_MAX_TIMESHIFT_PEERS:-}"
ACESTREAM_SLOTS_MANAGER_MIN_SLOTS="${ACESTREAM_SLOTS_MANAGER_MIN_SLOTS:-}"
ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT="${ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT:-}"
ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT="${ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT:-}"
ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT_PER_CORE="${ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT_PER_CORE:-}"
ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT_PER_CORE="${ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT_PER_CORE:-}"
ACESTREAM_SLOTS_MANAGER_BASE_BITRATE="${ACESTREAM_SLOTS_MANAGER_BASE_BITRATE:-}"
ACESTREAM_WANTED_SLOTS_FACTOR="${ACESTREAM_WANTED_SLOTS_FACTOR:-}"
ACESTREAM_STARTUP_SLOTS_FACTOR="${ACESTREAM_STARTUP_SLOTS_FACTOR:-}"
ACESTREAM_FIX_UPLOAD_SLOTS_INTERVAL="${ACESTREAM_FIX_UPLOAD_SLOTS_INTERVAL:-}"
ACESTREAM_LIVE_CACHE_TYPE="${ACESTREAM_LIVE_CACHE_TYPE:-auto}"
ACESTREAM_VOD_CACHE_TYPE="${ACESTREAM_VOD_CACHE_TYPE:-auto}"
ACESTREAM_LIVE_MEM_CACHE_SIZE="${ACESTREAM_LIVE_MEM_CACHE_SIZE:-}"
ACESTREAM_LIVE_DISK_CACHE_SIZE="${ACESTREAM_LIVE_DISK_CACHE_SIZE:-}"
ACESTREAM_MEMORY_CACHE_LIMIT="${ACESTREAM_MEMORY_CACHE_LIMIT:-}"
ACESTREAM_VOD_BUFFER="${ACESTREAM_VOD_BUFFER:-30}"
ACESTREAM_LOG_STDOUT_LEVEL="${ACESTREAM_LOG_STDOUT_LEVEL:-info}"
ACESTREAM_LOG_MAX_SIZE="${ACESTREAM_LOG_MAX_SIZE:-10485760}"
ACESTREAM_LOG_BACKUP_COUNT="${ACESTREAM_LOG_BACKUP_COUNT:-1}"
ACESTREAM_VERBOSE_MODULES="${ACESTREAM_VERBOSE_MODULES:-}"
# Power-user passthrough appended after every generated flag (argparse gives
# the last occurrence priority). Managed options are rejected by validation.
ACESTREAM_EXTRA_FLAGS="${ACESTREAM_EXTRA_FLAGS:-}"
API_PORT="${ACESTREAM_HTTP_PORT:-6878}"
ENGINE_FLAGS=()
RESOLVED_LIVE_CACHE_TYPE=""
RESOLVED_VOD_CACHE_TYPE=""

# Check before spawning either background loop. Canonical decimal integers
# avoid Bash's octal interpretation and arithmetic expansion of user input.
# Options miniace owns: derived from dedicated variables and kept in sync
# with the engine's persisted client settings, so ACESTREAM_EXTRA_FLAGS must
# not set them (a duplicate would fight the settings sync after restarts).
MANAGED_FLAG_NAMES=(
  max-connections max-peers max-upload-slots
  upload-limit download-limit fix-upload-slots
  cache-limit cache-dir state-dir
  live-cache-type vod-cache-type live-mem-cache-size live-disk-cache-size
  memory-cache-limit disk-cache-limit vod-buffer
  http-port port bind-all client-console api-port
)

validate_extra_flags() {
  local token flag managed extra_tokens=()
  read -r -a extra_tokens <<< "$ACESTREAM_EXTRA_FLAGS"
  for token in "${extra_tokens[@]}"; do
    if [[ ! "$token" =~ ^--[a-z0-9][a-z0-9-]*(=.+)?$ ]]; then
      echo "engine: ERROR: ACESTREAM_EXTRA_FLAGS token '$token' is not a --flag[=value] option" >&2
      return 1
    fi
    flag=${token#--}
    flag=${flag%%=*}
    for managed in "${MANAGED_FLAG_NAMES[@]}"; do
      if [[ "$flag" == "$managed" ]]; then
        echo "engine: ERROR: ACESTREAM_EXTRA_FLAGS token '$token' duplicates a managed option; set the dedicated ACESTREAM_* variable instead" >&2
        return 1
      fi
    done
  done
}

validate_engine_config() {
  local name value
  for name in ACESTREAM_MAX_CONNECTIONS ACESTREAM_MAX_PEERS_LIMIT \
    ACESTREAM_STARTUP_MAX_PEERS ACESTREAM_STARTUP_UPLOAD_SLOTS PORT_WATCH_INTERVAL_S; do
    value=${!name}
    if [[ ! "$value" =~ ^[1-9][0-9]{0,8}$ ]]; then
      echo "engine: ERROR: $name must be a positive decimal integer (1-999999999), got '$value'" >&2
      return 1
    fi
  done
  # Optional engine options: empty is valid and keeps the factory default.
  for name in ACESTREAM_UPLOAD_LIMIT ACESTREAM_DOWNLOAD_LIMIT \
    ACESTREAM_MAX_UPLOAD_SLOTS ACESTREAM_MIN_UPLOAD_SLOTS \
    ACESTREAM_MAX_TIMESHIFT_PEERS ACESTREAM_SLOTS_MANAGER_MIN_SLOTS \
    ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT \
    ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT_PER_CORE ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT_PER_CORE \
    ACESTREAM_SLOTS_MANAGER_BASE_BITRATE ACESTREAM_WANTED_SLOTS_FACTOR \
    ACESTREAM_STARTUP_SLOTS_FACTOR ACESTREAM_FIX_UPLOAD_SLOTS_INTERVAL \
    ACESTREAM_LIVE_MEM_CACHE_SIZE ACESTREAM_LIVE_DISK_CACHE_SIZE \
    ACESTREAM_MEMORY_CACHE_LIMIT ACESTREAM_LOG_MAX_SIZE ACESTREAM_LOG_BACKUP_COUNT; do
    value=${!name}
    if [[ -n "$value" && ! "$value" =~ ^(0|[1-9][0-9]{0,19})$ ]]; then
      echo "engine: ERROR: $name must be empty or a non-negative decimal integer, got '$value'" >&2
      return 1
    fi
  done
  if [[ ! "$ACESTREAM_CACHE_LIMIT_GB" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
    echo "engine: ERROR: ACESTREAM_CACHE_LIMIT_GB must be a non-negative decimal integer (0-999999999)" >&2
    return 1
  fi
  if [[ ! "$ACESTREAM_VOD_BUFFER" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "engine: ERROR: ACESTREAM_VOD_BUFFER must be a positive decimal integer, got '$ACESTREAM_VOD_BUFFER'" >&2
    return 1
  fi
  for name in ACESTREAM_FIX_UPLOAD_SLOTS ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT; do
    value=${!name}
    if [[ "$value" != 0 && "$value" != 1 ]]; then
      echo "engine: ERROR: $name must be 0 or 1" >&2
      return 1
    fi
  done
  for name in ACESTREAM_LIVE_CACHE_TYPE ACESTREAM_VOD_CACHE_TYPE; do
    value=${!name}
    if [[ ! "$value" =~ ^(auto|disk|memory)$ ]]; then
      echo "engine: ERROR: $name must be auto, disk or memory, got '$value'" >&2
      return 1
    fi
  done
  if [[ ! "$ACESTREAM_LOG_STDOUT_LEVEL" =~ ^(error|info|debug|any)$ ]]; then
    echo "engine: ERROR: ACESTREAM_LOG_STDOUT_LEVEL must be error, info, debug or any, got '$ACESTREAM_LOG_STDOUT_LEVEL'" >&2
    return 1
  fi
  if [[ -n "$ACESTREAM_VERBOSE_MODULES" && ! "$ACESTREAM_VERBOSE_MODULES" =~ ^[A-Za-z0-9_,.-]+$ ]]; then
    echo "engine: ERROR: ACESTREAM_VERBOSE_MODULES must be a comma-separated module list, got '$ACESTREAM_VERBOSE_MODULES'" >&2
    return 1
  fi
  if (( ACESTREAM_STARTUP_UPLOAD_SLOTS > ACESTREAM_STARTUP_MAX_PEERS \
    || ACESTREAM_STARTUP_MAX_PEERS > ACESTREAM_MAX_PEERS_LIMIT \
    || ACESTREAM_MAX_PEERS_LIMIT > ACESTREAM_MAX_CONNECTIONS )); then
    echo "engine: ERROR: require startup upload slots <= startup peers <= peer limit <= total connections" >&2
    return 1
  fi
  validate_extra_flags || return 1
}

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
  for (( i=0; i<10; i++ )); do
    [[ -z "$(engine_pids)" ]] && return 0
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

# Populate an argument array: paths must survive spaces and glob characters.
# Live slots scale automatically, so max-upload-slots alone would not raise
# their adaptive ceiling. Set both the startup budget and max-peers-limit.
# resolve_cache_types() fills the globals used by engine_init's log line and
# by configure_engine.
resolve_cache_types() {
  RESOLVED_LIVE_CACHE_TYPE=$ACESTREAM_LIVE_CACHE_TYPE
  RESOLVED_VOD_CACHE_TYPE=$ACESTREAM_VOD_CACHE_TYPE
  if [[ "$RESOLVED_LIVE_CACHE_TYPE" == auto ]]; then
    if (( ACESTREAM_CACHE_LIMIT_GB > 0 )); then RESOLVED_LIVE_CACHE_TYPE=disk; else RESOLVED_LIVE_CACHE_TYPE=memory; fi
  fi
  if [[ "$RESOLVED_VOD_CACHE_TYPE" == auto ]]; then
    if (( ACESTREAM_CACHE_LIMIT_GB > 0 )); then RESOLVED_VOD_CACHE_TYPE=disk; else RESOLVED_VOD_CACHE_TYPE=memory; fi
  fi
}

build_engine_flags() {
  local spec flag var value extra_tokens=()
  ENGINE_FLAGS=(
    "--state-dir=$ENGINE_STATE_DIR"
    "--cache-dir=$ENGINE_CACHE_DIR"
    "--upload-limit=$ACESTREAM_UPLOAD_LIMIT"
    "--download-limit=$ACESTREAM_DOWNLOAD_LIMIT"
    "--max-connections=$ACESTREAM_MAX_CONNECTIONS"
    "--max-peers=$ACESTREAM_STARTUP_MAX_PEERS"
    "--max-peers-limit=$ACESTREAM_MAX_PEERS_LIMIT"
    "--startup-max-peers=$ACESTREAM_STARTUP_MAX_PEERS"
    "--startup-upload-slots=$ACESTREAM_STARTUP_UPLOAD_SLOTS"
    "--fix-upload-slots=$ACESTREAM_FIX_UPLOAD_SLOTS"
    "--slots-manager-use-cpu-limit=$ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT"
  )
  # Optional options: an empty variable omits the flag (factory default).
  for spec in \
    "max-upload-slots ACESTREAM_MAX_UPLOAD_SLOTS" \
    "min-upload-slots ACESTREAM_MIN_UPLOAD_SLOTS" \
    "max-timeshift-peers ACESTREAM_MAX_TIMESHIFT_PEERS" \
    "slots-manager-min-slots ACESTREAM_SLOTS_MANAGER_MIN_SLOTS" \
    "slots-manager-cpu-low-limit ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT" \
    "slots-manager-cpu-high-limit ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT" \
    "slots-manager-cpu-low-limit-per-core ACESTREAM_SLOTS_MANAGER_CPU_LOW_LIMIT_PER_CORE" \
    "slots-manager-cpu-high-limit-per-core ACESTREAM_SLOTS_MANAGER_CPU_HIGH_LIMIT_PER_CORE" \
    "core-slots-manager-base-bitrate ACESTREAM_SLOTS_MANAGER_BASE_BITRATE" \
    "wanted-slots-factor ACESTREAM_WANTED_SLOTS_FACTOR" \
    "startup-slots-factor ACESTREAM_STARTUP_SLOTS_FACTOR" \
    "fix-upload-slots-interval ACESTREAM_FIX_UPLOAD_SLOTS_INTERVAL" \
    "live-mem-cache-size ACESTREAM_LIVE_MEM_CACHE_SIZE" \
    "live-disk-cache-size ACESTREAM_LIVE_DISK_CACHE_SIZE" \
    "memory-cache-limit ACESTREAM_MEMORY_CACHE_LIMIT" \
    "log-max-size ACESTREAM_LOG_MAX_SIZE" \
    "log-backup-count ACESTREAM_LOG_BACKUP_COUNT"
  do
    read -r flag var <<< "$spec"
    value=${!var}
    if [[ -n "$value" ]]; then
      ENGINE_FLAGS+=("--$flag=$value")
    fi
  done
  if [[ -n "$ACESTREAM_VERBOSE_MODULES" ]]; then
    ENGINE_FLAGS+=("--verbose=$ACESTREAM_VERBOSE_MODULES")
  fi
  resolve_cache_types
  ENGINE_FLAGS+=(
    "--live-cache-type=$RESOLVED_LIVE_CACHE_TYPE"
    "--vod-cache-type=$RESOLVED_VOD_CACHE_TYPE"
  )
  if (( ACESTREAM_CACHE_LIMIT_GB > 0 )); then
    ENGINE_FLAGS+=("--cache-limit=$ACESTREAM_CACHE_LIMIT_GB")
  fi
  # Extra flags last: argparse gives the last occurrence priority.
  read -r -a extra_tokens <<< "$ACESTREAM_EXTRA_FLAGS"
  if (( ${#extra_tokens[@]} > 0 )); then
    ENGINE_FLAGS+=("${extra_tokens[@]}")
  fi
}

# The client overwrites some CLI settings from its persistent player config.
# Apply through the supported API; exit 10 means a restart is needed to load
# the updated connection budget. The token is read inside Python, not argv.
configure_engine() {
  python3 /opt/miniace/configure_engine.py \
    --runtime-file "$ENGINE_HOME/engine_runtime.json" \
    --api-port "$API_PORT" \
    --max-connections "$ACESTREAM_MAX_CONNECTIONS" \
    --max-peers "$ACESTREAM_STARTUP_MAX_PEERS" \
    --max-upload-slots "$ACESTREAM_MAX_UPLOAD_SLOTS" \
    --upload-limit "$ACESTREAM_UPLOAD_LIMIT" \
    --download-limit "$ACESTREAM_DOWNLOAD_LIMIT" \
    --auto-slots "$ACESTREAM_FIX_UPLOAD_SLOTS" \
    --cache-dir "$ENGINE_CACHE_DIR" \
    --cache-limit-gb "$ACESTREAM_CACHE_LIMIT_GB" \
    --memory-cache-limit "$ACESTREAM_MEMORY_CACHE_LIMIT" \
    --live-cache-type "$RESOLVED_LIVE_CACHE_TYPE" \
    --vod-cache-type "$RESOLVED_VOD_CACHE_TYPE" \
    --vod-buffer "$ACESTREAM_VOD_BUFFER"
}

# Engine supervisor.
#
# Probe readiness independently of the launcher: it can stay in the
# foreground or leave a daemon behind. Blocking on its PID would prevent
# client settings from being applied while a foreground engine is running.
# The forwarded port is re-resolved on every spawn. Port rotations and
# settings changes respawn immediately; crashes back off (3 -> 60 s).
#
# NOTE on flag spelling: the engine parses value flags in the
# --flag=value form throughout, including the client's HTTP/P2P options.
# Performance preferences are parsed by Core.so in engine 3.2.11.
#   --http-port : HTTP API port (default 6878)
#   --port      : P2P session port (default 8621) <- bound to the
#                 Gluetun forwarded port
#   --log-file  : second log sink in the persisted state dir (rotation
#                 is fixed by the engine at 10MB + 1 backup; --log-stdout
#                 above keeps docker compose logs working)
#   --vod-buffer: VOD buffer in seconds, independent of live upload slots.
#                 3.2.11 also supports --live-cache-type and
#                 --live-mem-cache-size for live cache configuration.
start_engine() {
  # settings_restarts reserves immediate API-loss respawns while the settings
  # configuration has not yet been verified in this supervisor run. A budget
  # item is consumed on each API loss; it is refilled after the settings are
  # verified, and a full budget (fresh container start) does not consume it
  # for the first API loss on an already-verified profile.
  local backoff=3 profile_ready=0 active_p2p="" settings_restarts=0
  sweep_engine_leftovers
  while true; do
    if engine_api_alive; then
      if (( ! profile_ready )); then
        local settings_status=0
        configure_engine || settings_status=$?
        if (( settings_status != 0 )); then
          # Even a failed request may have changed persisted settings. Always
          # start a fresh daemon before retrying so native prefs reflect them.
          stop_engine
          if (( settings_status == 10 )); then
            echo "engine: restarting to load saved client settings"
            (( settings_restarts += 1 ))
          else
            echo "engine: client settings failed; retrying with a fresh engine in 5s" >&2
            sleep 5
          fi
          continue
        fi
        profile_ready=1
        # A verified profile grants one immediate API-loss respawn: the next
        # quiet period is a crash of the running daemon, not a repeating
        # settings restart. Later losses go through the backoff ladder below.
        settings_restarts=1
      fi
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
    if (( profile_ready )) && [[ "$p2p" == "$active_p2p" ]]; then
      profile_ready=0
      stop_engine
      if (( settings_restarts > 0 )); then
        (( settings_restarts -= 1 ))
        backoff=3
        echo "engine: API stopped responding; respawning immediately" >&2
      else
        backoff=$(( backoff * 2 ))
        if (( backoff > 60 )); then backoff=60; fi
        echo "engine: API stopped responding; retrying in ${backoff}s..." >&2
        sleep "$backoff"
      fi
      continue
    fi
    profile_ready=0
    stop_engine
    active_p2p=$p2p
    printf '%s\n' "$p2p" > "$ACTIVE_P2P_PORT_FILE" 2>/dev/null || true
    build_engine_flags
    echo "engine: starting AceStream (HTTP API on $API_PORT, P2P on forwarded port $p2p)"
    "$ENGINE_HOME/start-engine" \
      --client-console \
      --bind-all \
      --disable-sentry \
      --log-stdout \
      "--log-stdout-level=$ACESTREAM_LOG_STDOUT_LEVEL" \
      --log-file="$ENGINE_STATE_DIR/acestream.log" \
      "--log-max-size=$ACESTREAM_LOG_MAX_SIZE" \
      "--log-backup-count=$ACESTREAM_LOG_BACKUP_COUNT" \
      "--vod-buffer=$ACESTREAM_VOD_BUFFER" \
      --http-port="$API_PORT" \
      --port="$p2p" \
      "${ENGINE_FLAGS[@]}" 2>&1 &
    local pid=$!
    local ready=0 deadline=$(( SECONDS + 60 ))
    while (( SECONDS < deadline )); do
      if engine_api_alive; then
        ready=1
        break
      fi
      if ! kill -0 "$pid" 2>/dev/null && [[ -z "$(engine_pids)" ]]; then
        break
      fi
      sleep 1
    done
    if (( ready )); then
      backoff=3
      continue
    fi
    stop_engine
    wait "$pid" 2>/dev/null || true
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
  validate_engine_config || return 1
  resolve_cache_types
  mkdir -p "$STATE_DIR" "$ENGINE_STATE_DIR" "$ENGINE_CACHE_DIR" 2>/dev/null || true
  if (( ACESTREAM_CACHE_LIMIT_GB > 0 )); then
    echo "engine: state dir $ENGINE_STATE_DIR, cache dir $ENGINE_CACHE_DIR (live=$RESOLVED_LIVE_CACHE_TYPE vod=$RESOLVED_VOD_CACHE_TYPE, disk limit ${ACESTREAM_CACHE_LIMIT_GB}GB)"
  else
    echo "engine: state dir $ENGINE_STATE_DIR, cache dir $ENGINE_CACHE_DIR (live=$RESOLVED_LIVE_CACHE_TYPE vod=$RESOLVED_VOD_CACHE_TYPE, no disk cache limit)"
  fi
  echo "engine: upload profile: upload-limit=${ACESTREAM_UPLOAD_LIMIT:-0}Kb/s download-limit=${ACESTREAM_DOWNLOAD_LIMIT:-0}Kb/s, connections=$ACESTREAM_MAX_CONNECTIONS, startup peers=$ACESTREAM_STARTUP_MAX_PEERS, peer limit=$ACESTREAM_MAX_PEERS_LIMIT, startup slots=$ACESTREAM_STARTUP_UPLOAD_SLOTS, adaptive slots=$ACESTREAM_FIX_UPLOAD_SLOTS, CPU brake=$ACESTREAM_SLOTS_MANAGER_USE_CPU_LIMIT"
  if ! curl -fsS --max-time 2 "$GLUETUN_CONTROL_BASE/v1/portforward" >/dev/null 2>&1 \
     && [[ ! -s "$GLUETUN_PORT_FILE" ]]; then
    echo "engine: WARNING: Gluetun control server ($GLUETUN_CONTROL_BASE) is not reachable yet and $GLUETUN_PORT_FILE is empty; the engine will wait for a forwarded port" >&2
  fi
}
