#!/bin/bash
set -uo pipefail

# --- Environment --------------------------------------------------------
STEAMCMD_PATH="${STEAMCMD_PATH:-/home/pzuser/steamcmd}"
PZ_PATH="${PZ_PATH:-/opt/pzserver}"
STEAM_APP_ID="${STEAM_APP_ID:-380870}"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
CODE_SERVER_PASSWORD="${CODE_SERVER_PASSWORD:-}"
SERVER_NAME="${SERVER_NAME:-server}"
PZ_HEAP="${PZ_HEAP:-2g}"
# -Xms. Deliberately NOT equal to PZ_HEAP: committing the whole heap in the
# first second of boot is what used to hang the 6 GB VM.
PZ_HEAP_MIN="${PZ_HEAP_MIN:-512m}"
# Mirrors compose's `cpus:` so the JVM can be told how many CPUs it really has.
PZ_CPUS="${PZ_CPUS:-3}"
ENABLE_CODE_SERVER="${ENABLE_CODE_SERVER:-false}"
RCON_PASSWORD="${RCON_PASSWORD:-}"
RCON_PORT="${RCON_PORT:-27015}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
PUBLIC_NAME="${PUBLIC_NAME:-}"
PUBLIC_DESCRIPTION="${PUBLIC_DESCRIPTION:-}"
PZ_BRANCH="${PZ_BRANCH:-}"
PZ_AUTO_UPDATE="${PZ_AUTO_UPDATE:-true}"

PROFILE_DIR="/home/pzuser/Zomboid/Server"
TEMPLATE_DIR="/home/pzuser/profile-template"
INI="${PROFILE_DIR}/${SERVER_NAME}.ini"

# Which branch the installed copy came from. Lives in the pzserver-install
# volume so it is discarded together with the installation it describes.
BRANCH_MARKER="${PZ_PATH}/.pz-installed-branch"
PZ_BRANCH_LABEL="${PZ_BRANCH:-public}"

# PZ does not reliably bind RCON on 0.0.0.0, so talk to the container's own
# address rather than localhost.
SERVER_IP="$(hostname -i | awk '{print $1}')"

pz_pid=""

log() { echo "[start.sh] $*"; }
err() { echo "[start.sh] $*" >&2; }

# is_truthy <value> — the one spelling of "on" used by every boolean env here.
is_truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Which copy of this script is actually running. The container executes
# /start.sh from the IMAGE (Dockerfile: COPY start.sh /start.sh), NOT the
# start.sh sitting in the deploy directory — so uploading a new one and running
# `docker compose up -d` without `--build` leaves the old script in charge, with
# no visible sign of it. Compare this sha against `sha256sum server/start.sh`
# in the repo to tell in one glance.
log "revision: $0 $(date -r "$0" -u +%Y-%m-%dT%H:%MZ) sha $(sha256sum "$0" | cut -c1-12)"

if [ -z "$ADMIN_PASSWORD" ]; then
  err "ADMIN_PASSWORD is not set — refusing to start."
  exit 1
fi

if [ -z "$CODE_SERVER_PASSWORD" ]; then
  err "CODE_SERVER_PASSWORD is not set — refusing to start."
  exit 1
fi

# --- code-server --------------------------------------------------------
# Off by default. It shares this container's cgroup, so its ~300-500 MB come
# straight out of the same mem_limit the game has to fit in — on a 6 GB VM that
# is a meaningful slice of the budget. Turn it on when you need to edit the
# .ini, then turn it back off.
#
# The password is still required unconditionally (compose uses `:?`) so that
# enabling this is a one-flag change that can never leave :8443 unauthenticated.
# Deliberately NOT ADMIN_PASSWORD: :8443 is published without TLS, so the web
# IDE login is a separate secret from the in-game admin account.
if is_truthy "$ENABLE_CODE_SERVER"; then
  export PASSWORD="$CODE_SERVER_PASSWORD"
  # niced: PZ's boot is the latency-sensitive workload, the IDE is not.
  nice -n 10 code-server --bind-addr 0.0.0.0:8443 --auth password &
  log "code-server listening on 0.0.0.0:8443"
else
  log "code-server disabled (set ENABLE_CODE_SERVER=true in .env to enable)."
fi

# --- Project Zomboid install / update -----------------------------------
# The game is NOT baked into the Docker image; it lives in the pzserver-install
# volume and is installed/updated here on every boot.
#
# app_update is the ONLY install path that works with `login anonymous`.
# download_depot (exact-manifest pinning) is not usable: an anonymous account
# gets a license for the app but not for its depots, and Steam answers with
# "Depot download failed : missing license for depot (No subscription)".
# Version pinning therefore happens through PZ_BRANCH / -beta.

install_via_app_update() {
  local args=(
    +@sSteamCmdForcePlatformType linux
    +force_install_dir "$PZ_PATH"
    +login anonymous
    +app_update "$STEAM_APP_ID"
  )
  [ -n "$PZ_BRANCH" ] && args+=(-beta "$PZ_BRANCH")
  args+=(validate +quit)

  local attempt out
  for attempt in 1 2 3; do
    log "SteamCMD app_update attempt ${attempt}/3${PZ_BRANCH:+ (branch: ${PZ_BRANCH})}"
    out="$("${STEAMCMD_PATH}/steamcmd.sh" "${args[@]}" 2>&1)"
    echo "$out"
    # The installed file is the source of truth; SteamCMD's exit code is not.
    [ -f "${PZ_PATH}/start-server.sh" ] && return 0

    # Separate a config error from a transient one — retrying a bad branch name
    # for eternity under `restart: unless-stopped` is a silent restart loop.
    case "$out" in
      *"Failed to set beta"*|*"No subscription"*|*"missing license"*)
        err "FATAL: this is a configuration error, not a transient failure."
        err "PZ_BRANCH='${PZ_BRANCH}' was rejected by Steam. Valid branches:"
        err "  curl -s https://api.steamcmd.net/v1/info/380870 | jq '.data[\"380870\"].depots.branches'"
        err "Leave PZ_BRANCH empty to track the public branch. Retrying will not help."
        return 1
        ;;
    esac

    # A cold appinfo cache can fail with "Missing configuration"; a stale
    # manifest can wedge the update. Drop it and retry.
    rm -f "${PZ_PATH}/steamapps/appmanifest_${STEAM_APP_ID}.acf"
    err "SteamCMD attempt ${attempt}/3 failed. Retrying in 15s."
    sleep 15
  done
  return 1
}

# PZ_BRANCH='' (the public branch) is NOT a pin — it moves on its own, and there
# is no frozen branch for every build (42.20 never got one). The real pin is the
# marker below: while the installed branch is the requested one and
# PZ_AUTO_UPDATE is off, app_update is skipped entirely, so a restart cannot
# bump the server past clients that have not updated yet. Flip PZ_AUTO_UPDATE to
# true for one boot to move to the branch's current build.
needs_install() {
  [ -f "${PZ_PATH}/start-server.sh" ] || return 0
  [ "$(cat "$BRANCH_MARKER" 2>/dev/null)" = "$PZ_BRANCH_LABEL" ] || return 0
  is_truthy "$PZ_AUTO_UPDATE" && return 0
  return 1
}

if needs_install; then
  if install_via_app_update; then
    printf '%s\n' "$PZ_BRANCH_LABEL" > "$BRANCH_MARKER"
  else
    err "app_update failed — see the errors above."
  fi
else
  log "Skipping SteamCMD: branch '${PZ_BRANCH_LABEL}' already installed and PZ_AUTO_UPDATE=${PZ_AUTO_UPDATE}."
fi

if [ ! -f "${PZ_PATH}/start-server.sh" ]; then
  err "SteamCMD could not install app ${STEAM_APP_ID}."
  err "Backing off 60s so 'restart: unless-stopped' does not hammer Steam."
  sleep 60
  exit 1
fi

cd "$PZ_PATH" || { err "${PZ_PATH} is missing."; exit 1; }

# PZ looks for the Steam client library here. The Dockerfile stages it, but a
# build where SteamCMD's self-update misbehaved may have skipped it.
if [ ! -f /home/pzuser/.steam/sdk64/steamclient.so ] &&
   [ -f "${STEAMCMD_PATH}/linux64/steamclient.so" ]; then
  mkdir -p /home/pzuser/.steam/sdk64
  cp "${STEAMCMD_PATH}/linux64/steamclient.so" /home/pzuser/.steam/sdk64/steamclient.so
fi

# --- Server profile -----------------------------------------------------
# The repo ships a generic server.* template. Derive ${SERVER_NAME}.* from it
# the first time a given profile is used. An existing profile is never touched,
# which is what keeps a live deployment's config intact.
if [ ! -f "$INI" ] && [ -f "${TEMPLATE_DIR}/server.ini" ]; then
  log "Seeding profile '${SERVER_NAME}' from the server.* template."
  mkdir -p "$PROFILE_DIR"
  for suffix in ".ini" "_SandboxVars.lua" "_spawnpoints.lua" "_spawnregions.lua"; do
    src="${TEMPLATE_DIR}/server${suffix}"
    dst="${PROFILE_DIR}/${SERVER_NAME}${suffix}"
    [ -f "$src" ] && [ ! -f "$dst" ] && cp "$src" "$dst"
  done
fi

# --- JVM tuning ---------------------------------------------------------
# PZ's launcher reads JVM args from ProjectZomboid64.json, NOT from the
# start-server.sh command line — passing -Xmx as an arg is silently ignored.
# The stock value is 16g, which OOM-kills the container, so it must be patched.
#
# The heap is only part of the story. Metaspace, the code cache and direct
# buffers live OUTSIDE it and had no ceiling at all here; the "~1.5 GB of
# overhead" in the sizing rule was an estimate that nothing enforced. The
# -XX: flags below turn it into an actual budget.

# set_jvm_flag <file> <flag> <value> — replace the flag if present,
# otherwise append it to the vmArgs array. Returns 1 if it could do neither.
set_jvm_flag() {
  local file="$1" flag="$2" value="$3"
  if grep -q -- "$flag" "$file"; then
    sed -i -E "s|${flag}[^\"[:space:]]*|${flag}${value}|g" "$file"
  elif grep -q '"vmArgs"' "$file"; then
    sed -i -E "s|(\"vmArgs\"[[:space:]]*:[[:space:]]*\[)|\1\n\t\t\"${flag}${value}\",|" "$file"
  elif grep -qE -- '-Xm[sx][^"[:space:]]*' "$file"; then
    # No vmArgs array (shell launcher): insert next to the sibling heap flag.
    sed -i -E "0,/(-Xm[sx][^\"[:space:]]*)/s//${flag}${value} \1/" "$file"
  else
    return 1
  fi
}

# add_jvm_flag_once <file> <flag> — for valueless flags like
# -XX:+ExitOnOutOfMemoryError. set_jvm_flag cannot be used for these: its
# replace branch would eat whatever follows the flag, and its `+` is a regex
# metacharacter, hence the -F match here. No-op when already present.
add_jvm_flag_once() {
  local file="$1" flag="$2"
  if grep -qF -- "$flag" "$file"; then
    return 0
  elif grep -q '"vmArgs"' "$file"; then
    sed -i -E "s|(\"vmArgs\"[[:space:]]*:[[:space:]]*\[)|\1\n\t\t\"${flag}\",|" "$file"
  elif grep -qE -- '-Xm[sx][^"[:space:]]*' "$file"; then
    sed -i -E "0,/(-Xm[sx][^\"[:space:]]*)/s//${flag} \1/" "$file"
  else
    return 1
  fi
}

# The JVM sizes its GC and JIT thread pools from the CPUs it can SEE, which is
# the host's count — compose's `cpus:` is a CFS quota, not a mask, so it does
# not change that number. Left alone on a 4-vCPU VM the JVM spins up 4 GC
# threads and then gets throttled, which at boot is exactly when the machine
# could least afford it. Floor to an integer (PZ_CPUS accepts 3.5, the JVM does
# not) and never go below 1.
jvm_cpus="${PZ_CPUS%%.*}"
case "$jvm_cpus" in
  ''|*[!0-9]*|0) jvm_cpus=1 ;;
esac

HEAP_FILE=""
if [ -f ProjectZomboid64.json ]; then
  HEAP_FILE="ProjectZomboid64.json"
elif [ -f start-server.sh ]; then
  # Fallback: some layouts put the JVM args straight in the launcher script.
  HEAP_FILE="start-server.sh"
fi

if [ -n "$HEAP_FILE" ]; then
  set_jvm_flag "$HEAP_FILE" "-Xmx" "$PZ_HEAP" || err "WARNING: could not set -Xmx in $HEAP_FILE"
  # NOT PZ_HEAP. -Xms == -Xmx makes the JVM commit the entire heap in the first
  # second of boot, on top of SteamCMD's page cache and everything else starting
  # at once — which is the precise moment the 6 GB VM used to lock up. Let it
  # grow into memory instead.
  set_jvm_flag "$HEAP_FILE" "-Xms" "$PZ_HEAP_MIN" || err "WARNING: could not set -Xms in $HEAP_FILE"

  # Ceilings for the non-heap side of the budget.
  set_jvm_flag "$HEAP_FILE" "-XX:MaxMetaspaceSize=" "256m" ||
    err "WARNING: could not set -XX:MaxMetaspaceSize in $HEAP_FILE"
  set_jvm_flag "$HEAP_FILE" "-XX:MaxDirectMemorySize=" "512m" ||
    err "WARNING: could not set -XX:MaxDirectMemorySize in $HEAP_FILE"
  set_jvm_flag "$HEAP_FILE" "-XX:ActiveProcessorCount=" "$jvm_cpus" ||
    err "WARNING: could not set -XX:ActiveProcessorCount in $HEAP_FILE"
  # Without this a heap OOM leaves a JVM that is alive but useless: the process
  # still exists, so the healthcheck's pgrep keeps reporting healthy and
  # `restart: unless-stopped` never fires. Die instead, and let Docker restart.
  add_jvm_flag_once "$HEAP_FILE" "-XX:+ExitOnOutOfMemoryError" ||
    err "WARNING: could not set -XX:+ExitOnOutOfMemoryError in $HEAP_FILE"

  heap_flags="$(grep -o -- '-Xm[sx][^"[:space:]]*' "$HEAP_FILE" | tr '\n' ' ')"
  log "JVM heap in ${HEAP_FILE}: ${heap_flags}"
  log "JVM limits in ${HEAP_FILE}: $(grep -o -- '-XX:[^"[:space:]]*' "$HEAP_FILE" | tr '\n' ' ')"
  # Read the file back: a layout change in a future build would make the sed a
  # no-op, and the only visible symptom would be the server quietly running on
  # the stock 16g heap.
  case " ${heap_flags}" in
    *" -Xmx${PZ_HEAP} "*) ;;
    *)
      err "WARNING: PZ_HEAP='${PZ_HEAP}' did NOT land in ${HEAP_FILE} (found: ${heap_flags:-nothing})."
      err "         The server is about to start on that heap, not on PZ_HEAP."
      ;;
  esac
  case " ${heap_flags}" in
    *" -Xms${PZ_HEAP_MIN} "*) ;;
    *)
      err "WARNING: PZ_HEAP_MIN='${PZ_HEAP_MIN}' did NOT land in ${HEAP_FILE} (found: ${heap_flags:-nothing})."
      err "         If -Xms still equals -Xmx, the JVM commits the whole heap at boot."
      ;;
  esac
else
  err "WARNING: no ProjectZomboid64.json or start-server.sh to patch — heap stays at the stock 16g."
fi

# --- Memory budget ------------------------------------------------------
# PZ_HEAP and the container's memory limit are two different ceilings and both
# matter. The heap is JVM-only; the cgroup limit also has to cover JVM non-heap
# (metaspace, code cache, per-player threads, direct buffers), PZ's native
# allocations and code-server — roughly 1.5 GB on top of the heap.
#
# A cgroup limit ABOVE the host's RAM is not a limit at all: the cgroup never
# fills, Docker never throttles the container, and the host OOM killer is what
# ends up choosing a victim — which looks exactly like "PZ_HEAP is ignored".
# But "at most the host's RAM" is not enough either, and that is the bug this
# check used to have: a limit of 4608m on a 6144m VM passed silently while
# leaving the host ~1.5 GB for kernel + dockerd + sshd + the page cache PZ
# streams its map through. Under that pressure, with no swap anywhere, the
# kernel livelocks reclaiming instead of OOM-killing — the whole VM freezes and
# logs nothing. So the limit must leave HOST_RESERVE_B on the table, and that
# reserve is deliberately LARGER than the container's own overhead.
#
# Warn loudly, but do NOT exit (under `restart: unless-stopped` that is a
# restart loop) and do NOT silently clamp the heap, which would hide the very
# misconfiguration this is here to surface.

# Two DIFFERENT reserves. Making them the same number is a trap: at 1.5 GiB
# each, a 4608m limit on a 6144m VM lands exactly on the boundary and passes —
# and 4608m on 6144m is the config that froze the VM. The host needs more than
# the container's own overhead, because the page cache PZ streams its map
# through lives on the host side of the ledger.
CONTAINER_OVERHEAD_B=$(( 1536 * 1024 * 1024 ))  # JVM non-heap + PZ native + code-server
HOST_RESERVE_B=$(( 2048 * 1024 * 1024 ))        # kernel + systemd + dockerd + sshd + page cache

# to_bytes <3g|4608m|2048k|12345> — prints bytes; returns 1 if unparseable.
to_bytes() {
  local v n unit
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  n="${v%%[gmk]}"
  unit="${v#"$n"}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    g) echo $(( n * 1024 * 1024 * 1024 )) ;;
    m) echo $(( n * 1024 * 1024 )) ;;
    k) echo $(( n * 1024 )) ;;
    '') echo "$n" ;;
    *) return 1 ;;
  esac
}

gib() {
  [ "${1:-0}" -eq 0 ] && { printf 'unlimited'; return 0; }
  awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'
}

# Same formatting, but 0 means "there is none" rather than "there is no cap" —
# which is the right reading for swap.
gib2() {
  [ "${1:-0}" -eq 0 ] && { printf 'none'; return 0; }
  awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'
}

report_memory_budget() {
  local heap_b limit_raw limit_b host_b headroom swap_b host_cpus

  heap_b="$(to_bytes "$PZ_HEAP")" || {
    err "WARNING: PZ_HEAP='${PZ_HEAP}' is not a size the JVM understands (expected e.g. 2g)."
    return 0
  }

  # cgroup v2 first, v1 as the fallback. v2 reports an uncapped container as
  # the literal string 'max'; v1 reports a huge sentinel number.
  limit_raw="$(cat /sys/fs/cgroup/memory.max 2>/dev/null ||
               cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
  case "$limit_raw" in
    ''|*[!0-9]*) limit_b=0 ;;
    *) limit_b="$limit_raw" ;;
  esac
  # /proc/meminfo inside the container still reports the HOST's RAM, which is
  # what makes the "limit above physical RAM" comparison possible.
  host_b=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024 ))

  swap_b=$(( $(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo) * 1024 ))
  host_cpus="$(nproc 2>/dev/null || echo 0)"

  log "Memory budget: heap ${PZ_HEAP} ($(gib "$heap_b")) | container limit $(gib "$limit_b") | host RAM $(gib "$host_b") | host swap $(gib2 "$swap_b")"
  log "CPU budget: PZ_CPUS=${PZ_CPUS} (JVM told ${jvm_cpus}) | host nproc ${host_cpus}"

  # Rule 2: the limit must leave the HOST its reserve, not merely fit inside
  # total RAM. "At most the VM's RAM" was the old rule and it is what let a
  # 4608m limit sit on a 6144m VM: the ~1.5 GB left over had to cover kernel,
  # dockerd, sshd and the page cache PZ streams its map through.
  if [ "$limit_b" -eq 0 ] || [ $(( limit_b + HOST_RESERVE_B )) -gt "$host_b" ]; then
    err "WARNING: the container limit ($(gib "$limit_b")) does not leave the host its $(gib "$HOST_RESERVE_B") reserve out of $(gib "$host_b")."
    err "         The host needs that for kernel, dockerd, sshd and page cache. Without it the VM can"
    err "         livelock reclaiming memory instead of OOM-killing anything — the whole machine hangs,"
    err "         SSH included, and nothing is logged."
    err "         Set PZ_MEM_LIMIT to at most $(gib $(( host_b - HOST_RESERVE_B ))) — see the table in .env.example."
  fi

  # Rule 1: headroom for the non-heap side. 1.5 GB, matching the rule quoted
  # everywhere else — this used to warn at 1 GB and silently pass sizings the
  # project's own documentation called under-provisioned.
  if [ "$limit_b" -gt 0 ]; then
    headroom=$(( limit_b - heap_b ))
    if [ "$headroom" -lt "$CONTAINER_OVERHEAD_B" ]; then
      err "WARNING: only $(gib "$headroom") of headroom between the heap and the container limit."
      err "         JVM non-heap, PZ's native allocations and code-server need ~1.5 GB on top of the heap,"
      err "         so the JVM will be OOM-killed as the heap fills. Lower PZ_HEAP or raise PZ_MEM_LIMIT"
      err "         (rule of thumb: PZ_MEM_LIMIT ~= PZ_HEAP + 1.5 GB, and <= the VM's RAM - 2 GB)."
    fi
  fi

  # No host swap is the condition that turns an overshoot into a frozen VM
  # rather than a dead container: with nowhere to evict anonymous pages the
  # kernel never reaches a clean OOM. This was completely invisible until now.
  if [ "$swap_b" -eq 0 ]; then
    err "WARNING: the host has NO swap. An overshoot here cannot end in a clean OOM kill — the kernel"
    err "         stalls reclaiming and the VM freezes, taking SSH with it and logging nothing."
    err "         Run 'sudo bash vm-hardening.sh' on the VM once (swapfile, vm.min_free_kbytes, earlyoom)."
  fi

  # Rule 3: leave the host a core, or sshd stops being scheduled while the JVM
  # and chunk streaming saturate every vCPU at boot.
  if [ "$host_cpus" -gt 0 ] && [ "$jvm_cpus" -ge "$host_cpus" ]; then
    err "WARNING: PZ_CPUS=${PZ_CPUS} leaves the host no spare vCPU (nproc=${host_cpus})."
    err "         At boot the JVM and chunk loading can occupy all of them and sshd stops responding,"
    err "         which is indistinguishable from a crashed VM. Set PZ_CPUS=$(( host_cpus - 1 ))."
  fi
}

report_memory_budget

# --- Server identity in the .ini ----------------------------------------
# set_ini_key <key> <value> — writes only when the value is non-empty, so an
# unset env var leaves whatever is already in the volume alone.
set_ini_key() {
  local key="$1" value="$2" esc
  [ -z "$value" ] && return 0
  [ -f "$INI" ] || { err "WARNING: ${INI} not found — cannot set ${key}."; return 1; }
  # '|' delimiter: generated passwords can contain '/'. Escape the characters
  # sed treats specially in a replacement.
  esc="${value//\\/\\\\}"
  esc="${esc//&/\\&}"
  esc="${esc//|/\\|}"
  if grep -qE "^${key}=" "$INI"; then
    sed -i -E "s|^${key}=.*|${key}=${esc}|" "$INI"
  else
    printf '%s=%s\n' "$key" "$value" >> "$INI"
  fi
}

set_ini_key RCONPort "$RCON_PORT"
set_ini_key RCONPassword "$RCON_PASSWORD"
set_ini_key Password "$SERVER_PASSWORD"
set_ini_key PublicName "${PUBLIC_NAME:-$SERVER_NAME}"
set_ini_key PublicDescription "$PUBLIC_DESCRIPTION"

# UPnP is pointless in a container — compose publishes the ports explicitly —
# and PZ itself warns it can hang the boot ("If the server hangs here, set
# UPnP=false"). Forced here rather than only in the template so it also reaches
# volumes that already exist, where the template never lands.
set_ini_key UPnP false

if [ -z "$RCON_PASSWORD" ]; then
  err "WARNING: RCON_PASSWORD is empty — RCON is unauthenticated and shutdown falls back to SIGTERM."
fi

# --- Run ----------------------------------------------------------------
# PZ's start-server.sh builds LD_LIBRARY_PATH pointing at jre64/lib/amd64 — the
# old JDK8 layout, which does not exist in the bundled JRE — so its
# LD_PRELOAD of libjsig.so fails with "cannot be preloaded". libjsig is the JVM's
# signal-chaining library, which is exactly what the SIGTERM fallback in
# shutdown_pz depends on. Export the real paths here: start-server.sh appends
# ${LD_LIBRARY_PATH} to its own assignment, so this survives. Do not patch
# start-server.sh itself — SteamCMD overwrites it on every app_update.
export LD_LIBRARY_PATH="${PZ_PATH}/jre64/lib:${PZ_PATH}/jre64/lib/server:${LD_LIBRARY_PATH:-}"

# PZ deliberately runs in the BACKGROUND (no exec): docker stop must trigger an
# RCON 'quit', which is the ordered shutdown — warn, save the world, exit.
shutdown_pz() {
  [ -z "$pz_pid" ] && exit 0
  if [ -n "$RCON_PASSWORD" ]; then
    log "Sending 'quit' over RCON to ${SERVER_IP}:${RCON_PORT}"
    rcon -a "${SERVER_IP}:${RCON_PORT}" -p "$RCON_PASSWORD" quit || {
      err "RCON quit failed — falling back to SIGTERM."
      kill -15 "$pz_pid"
    }
  else
    log "No RCON password — sending SIGTERM to pid ${pz_pid}"
    kill -15 "$pz_pid"
  fi
}
trap shutdown_pz TERM INT

log "Starting Project Zomboid server '${SERVER_NAME}'"
bash start-server.sh -servername "$SERVER_NAME" -adminpassword "$ADMIN_PASSWORD" &
pz_pid=$!

# A trap makes `wait` return immediately even though PZ is still saving, so
# `tail --pid` is what actually holds the container open until the save is
# finished. Without it the world gets cut off mid-write.
wait "$pz_pid"
tail --pid="$pz_pid" -f /dev/null
