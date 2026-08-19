#!/bin/bash
set -euo pipefail

# vm-hardening.sh — run ONCE on the VM that hosts the container, as root.
#
# The container limits in docker-compose.yml decide how much the server may
# take. This script decides what happens when something takes more anyway.
# Without it, the answer on the games-server VM was "the whole machine freezes,
# SSH included, and nothing is logged":
#
#   * No swap. With nowhere to evict anonymous pages, the kernel cannot reach a
#     clean OOM kill under pressure — it livelocks reclaiming instead. That is
#     the difference between a dead container and a dead VM.
#   * No reclaim reserve (vm.min_free_kbytes at its tiny default), which is what
#     lets that livelock start in the first place.
#   * No userspace OOM handler, so nothing acts in the window where the kernel
#     is still deciding.
#   * sshd as OOM-killable as anything else, so the one process you need to
#     diagnose the problem is fair game.
#   * Volatile journald, so a hard reboot erases the evidence of what happened.
#
# Everything here is idempotent: re-running it is a no-op once applied.
#
# Usage:
#   sudo bash vm-hardening.sh [--dry-run] [--swap-size-mb N]

RESET='\033[0m'
GREEN='\033[32m'      # INFO
YELLOW='\033[33m'     # WARNING
RED='\033[31m'        # ERROR
CYAN='\033[36m'       # DEBUG

DRY_RUN=false
SWAP_SIZE_MB=4096
SWAP_FILE=/swapfile
SYSCTL_FILE=/etc/sysctl.d/99-pz-server.conf
CHANGED=()

log() {
	local message="$1" log_level="${2:-INFO}" color="$RESET" timestamp
	timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	case "$log_level" in
	DEBUG) color="$CYAN" ;;
	INFO) color="$GREEN" ;;
	WARNING) color="$YELLOW" ;;
	ERROR | CRITICAL) color="$RED" ;;
	esac
	printf "%b%s%b - %s - %s\n" "$color" "$log_level" "$RESET" "$timestamp" "$message"
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [--dry-run] [--swap-size-mb N]

Prepares the VM so that an over-committed Project Zomboid container dies on its
own instead of freezing the whole machine.

Options:
  --dry-run           Print what would change without touching the system.
  --swap-size-mb N    Size of ${SWAP_FILE} when it has to be created (default: ${SWAP_SIZE_MB}).
  -h, --help          Show this help.
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--swap-size-mb)
			[[ $# -ge 2 ]] || {
				log "--swap-size-mb needs a value" "ERROR"
				exit 1
			}
			SWAP_SIZE_MB="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			log "Unknown argument: $1" "ERROR"
			usage
			exit 1
			;;
		esac
	done
}

# run <cmd...> — the single place where anything mutating happens, so --dry-run
# is honoured by construction rather than by remembering to check it.
run() {
	if [[ "$DRY_RUN" == "true" ]]; then
		log "would run: $*" "DEBUG"
	else
		"$@"
	fi
}

# write_file <path> <<<content — same idea for file contents.
write_file() {
	local path="$1" content
	content="$(cat)"
	if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
		log "${path} already has the wanted contents."
		return 1
	fi
	if [[ "$DRY_RUN" == "true" ]]; then
		log "would write ${path}:" "DEBUG"
		printf '%s\n' "$content" | sed 's/^/    /'
	else
		printf '%s\n' "$content" >"$path"
		log "Wrote ${path}"
	fi
	return 0
}

require_root() {
	if [[ "$DRY_RUN" == "true" ]]; then
		return 0
	fi
	if [[ "$(id -u)" -ne 0 ]]; then
		log "This script changes system configuration and must run as root: sudo bash $(basename "$0")" "CRITICAL"
		exit 1
	fi
}

# --- 1. Disk ------------------------------------------------------------
# Advisory only. The Project Zomboid install alone is ~7 GB in the
# pzserver-install volume, and this VM has been observed at 90% full. A full
# disk stalls Docker in ways that look a lot like the memory problem, and the
# swapfile below needs room of its own.
check_disk() {
	local avail_mb
	avail_mb=$(df -Pm / | awk 'NR==2 { print $4 }')
	log "Root filesystem: $(df -Ph / | awk 'NR==2 { print $4 " free of " $2 }')"
	if [[ "$avail_mb" -lt $((SWAP_SIZE_MB + 2048)) ]]; then
		log "Only ${avail_mb} MB free — not enough for a ${SWAP_SIZE_MB} MB swapfile plus margin." "ERROR"
		log "Free space up or pass a smaller --swap-size-mb, then re-run." "ERROR"
		# Still worth completing a dry run: the point of --dry-run is to see the
		# whole plan, including the parts that come after this one.
		[[ "$DRY_RUN" == "true" ]] || exit 1
	fi
	if [[ "$avail_mb" -lt 10240 ]]; then
		log "Less than 10 GB free. The PZ install is ~7 GB; a full disk hangs Docker too." "WARNING"
	fi
}

# --- 2. Swap ------------------------------------------------------------
# Not there to be used in normal operation — vm.swappiness=10 below keeps the
# kernel off it — but to give reclaim somewhere to go under pressure, so an
# overshoot degrades into "slow" instead of "frozen". It is also what makes
# PZ_MEMSWAP_LIMIT > PZ_MEM_LIMIT in docker-compose.yml mean anything.
setup_swap() {
	if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
		log "Swap already active:"
		swapon --show | sed 's/^/    /'
		return 0
	fi

	log "No active swap — creating ${SWAP_FILE} (${SWAP_SIZE_MB} MB)."

	if [[ ! -f "$SWAP_FILE" ]]; then
		# fallocate leaves holes, which mkswap rejects on btrfs and some other
		# filesystems. dd is slower but always produces a usable swapfile.
		local fstype
		fstype=$(findmnt -no FSTYPE -T / 2>/dev/null || echo unknown)
		if [[ "$fstype" == "btrfs" ]]; then
			log "Root is btrfs — using dd instead of fallocate." "DEBUG"
			run dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
		else
			run fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE"
		fi
	fi

	run chmod 600 "$SWAP_FILE"
	run mkswap "$SWAP_FILE"
	run swapon "$SWAP_FILE"

	if ! grep -qE "^[^#]*[[:space:]]${SWAP_FILE}[[:space:]]|^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
		if [[ "$DRY_RUN" == "true" ]]; then
			log "would append to /etc/fstab: ${SWAP_FILE} none swap sw 0 0" "DEBUG"
		else
			printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>/etc/fstab
			log "Added ${SWAP_FILE} to /etc/fstab so it survives reboots."
		fi
	else
		log "${SWAP_FILE} already in /etc/fstab."
	fi
	CHANGED+=("swap")
}

# --- 3. sysctl ----------------------------------------------------------
setup_sysctl() {
	if write_file "$SYSCTL_FILE" <<-EOF
		# Managed by vm-hardening.sh (project-zomboid-server).

		# Swap is a safety net, not storage. Keep the kernel off it until it is
		# genuinely short of memory.
		vm.swappiness = 10

		# THE anti-freeze knob. This is the pool the kernel keeps free so that
		# reclaim itself has memory to work with. At the tiny default, a machine
		# under memory pressure can spend minutes spinning in reclaim without
		# ever reaching a clean OOM kill — which is what "the VM hangs and I lose
		# SSH" actually was. 128 MB on a 6 GB VM.
		vm.min_free_kbytes = 131072

		# PZ mmaps a lot of map chunks and assets. Reclaim that cache a little
		# more eagerly than the default so it does not crowd out anonymous memory.
		vm.vfs_cache_pressure = 50
	EOF
	then
		run sysctl --system >/dev/null
		CHANGED+=("sysctl")
	fi
	if [[ "$DRY_RUN" != "true" ]]; then
		log "Effective: swappiness=$(sysctl -n vm.swappiness) min_free_kbytes=$(sysctl -n vm.min_free_kbytes)"
	fi
}

# --- 4. earlyoom --------------------------------------------------------
# The kernel OOM killer only acts once reclaim has already failed, which on a
# small VM is well past the point where the machine stopped responding.
# earlyoom watches from userspace and kills sooner — and, crucially, kills the
# thing that is eating memory rather than whatever the kernel's heuristic picks.
setup_earlyoom() {
	if ! command -v earlyoom >/dev/null 2>&1; then
		log "Installing earlyoom."
		run apt-get update -qq
		run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom
		CHANGED+=("earlyoom")
	else
		log "earlyoom already installed."
	fi

	# --avoid protects what you need to get back in and diagnose; --prefer aims
	# at the JVM, which is the only process here that can plausibly run away.
	#
	# The regexes are UNQUOTED on purpose. earlyoom.service does
	# `ExecStart=/usr/bin/earlyoom $EARLYOOM_ARGS`, and systemd splits an
	# unquoted variable on whitespace WITHOUT stripping quotes afterwards —
	# wrapping these in '...' would hand earlyoom a regex with literal quote
	# characters in it. They contain no whitespace, so bare is correct.
	# Both patterns match the process NAME (comm), never a path: the JVM shows
	# up as `java`, not as ProjectZomboid64.
	if write_file /etc/default/earlyoom <<-'EOF'
		# Managed by vm-hardening.sh (project-zomboid-server).
		# -m / -s: act when available RAM / swap drops below this percentage.
		# --avoid: never pick these — losing sshd is how a recoverable incident
		#          becomes a trip to the hypervisor console.
		# --prefer: the JVM running Project Zomboid is the intended victim.
		EARLYOOM_ARGS="-m 8 -s 8 -r 3600 --avoid ^(sshd|systemd|dockerd|containerd|bash)$ --prefer ^(java)$"
	EOF
	then
		CHANGED+=("earlyoom-config")
	fi

	run systemctl enable earlyoom || true
	run systemctl restart earlyoom
	if [[ "$DRY_RUN" != "true" ]]; then
		log "earlyoom: $(systemctl is-active earlyoom)"
	fi
}

# --- 5. Protect sshd ----------------------------------------------------
# Whatever else happens, the box has to stay reachable. -900 makes sshd the
# last thing the kernel considers.
setup_sshd_oom() {
	local unit=""
	for candidate in ssh.service sshd.service; do
		if systemctl list-unit-files "$candidate" >/dev/null 2>&1 &&
			systemctl cat "$candidate" >/dev/null 2>&1; then
			unit="$candidate"
			break
		fi
	done

	if [[ -z "$unit" ]]; then
		log "No ssh.service or sshd.service found — skipping SSH OOM protection." "WARNING"
		return 0
	fi

	local dir="/etc/systemd/system/${unit}.d"
	run mkdir -p "$dir"
	if write_file "${dir}/oom.conf" <<-EOF
		# Managed by vm-hardening.sh (project-zomboid-server).
		# Keep SSH alive through a memory crunch: without this, the process you
		# need in order to fix the problem is as killable as the one causing it.
		[Service]
		OOMScoreAdjust=-900
	EOF
	then
		run systemctl daemon-reload
		run systemctl restart "$unit"
		log "Applied OOMScoreAdjust=-900 to ${unit}."
		CHANGED+=("sshd-oom")
	fi
}

# --- 6. Persistent journal ----------------------------------------------
# The reason there was no evidence: the default volatile journal lives in
# /run and a hard reboot takes it with it. Every freeze so far has been
# unexplainable for this reason alone.
setup_journald() {
	local conf=/etc/systemd/journald.conf
	if grep -qE '^[[:space:]]*Storage=persistent' "$conf" 2>/dev/null; then
		log "journald already persistent."
		return 0
	fi
	run mkdir -p /var/log/journal
	if [[ "$DRY_RUN" == "true" ]]; then
		log "would set Storage=persistent in ${conf}" "DEBUG"
	else
		if grep -qE '^[[:space:]]*#?[[:space:]]*Storage=' "$conf"; then
			sed -i -E 's|^[[:space:]]*#?[[:space:]]*Storage=.*|Storage=persistent|' "$conf"
		else
			printf 'Storage=persistent\n' >>"$conf"
		fi
		log "Set Storage=persistent in ${conf}"
	fi
	run systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
	run systemctl restart systemd-journald
	CHANGED+=("journald")
}

summary() {
	echo
	if [[ "$DRY_RUN" == "true" ]]; then
		log "Dry run — nothing was changed."
		return 0
	fi

	log "Done. Current state:"
	free -h | sed 's/^/    /'
	swapon --show 2>/dev/null | sed 's/^/    /' || true
	echo

	if [[ ${#CHANGED[@]} -eq 0 ]]; then
		log "Nothing needed changing — this VM was already hardened."
	else
		log "Changed: ${CHANGED[*]}"
	fi

	cat <<EOF

Next, in the deploy directory (this VM's .env is NOT overwritten by
upload_to_server.sh, so these have to be set by hand):

    PZ_HEAP=2g
    PZ_MEM_LIMIT=3584m
    PZ_MEMSWAP_LIMIT=4608m
    PZ_CPUS=3
    ENABLE_CODE_SERVER=false

Leave SERVER_NAME alone — changing it starts an empty world.

Then rebuild. --build is required: start.sh is baked into the image, so a plain
'up -d' keeps running the old one.

    docker compose up -d --build
    docker logs -f project-zomboid-server | grep -E 'revision:|budget|WARNING'

If it ever hangs again, the journal now survives the reboot:

    journalctl -k -b -1 | grep -iE 'oom|killed process'
    journalctl -u earlyoom -b -1
EOF
}

main() {
	parse_args "$@"
	log "Running vm-hardening.sh$([[ "$DRY_RUN" == "true" ]] && echo " (dry run)")"
	require_root
	check_disk
	setup_swap
	setup_sysctl
	setup_earlyoom
	setup_sshd_oom
	setup_journald
	summary
}

main "$@"
