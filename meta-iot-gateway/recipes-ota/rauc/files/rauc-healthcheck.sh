#!/bin/bash
# SPDX-License-Identifier: MIT
# rauc-healthcheck: mark booted slot good after basic system readiness

set -euo pipefail

log_info()  { echo "[$(date -Iseconds)] [INFO]  🩺 $*" >&2; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  ⚠️  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [ERROR] ❌ $*" >&2; }
die()       { log_error "$*"; exit 1; }

MIN_UPTIME_SEC=60

command -v rauc >/dev/null 2>&1 || die "rauc binary not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

prune_boot_backups() {
    local boot_mp="/boot"
    local keep="${MAX_BOOT_BACKUPS_AFTER_GOOD:-2}"
    local ro_before="0"
    local deleted=0
    local found=0
    local bases

    [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
    [ -d "$boot_mp" ] || return 0
    mountpoint -q "$boot_mp" || return 0

    if findmnt -no OPTIONS "$boot_mp" 2>/dev/null | grep -qw ro; then
        ro_before="1"
        mount -o remount,rw "$boot_mp" >/dev/null 2>&1 || {
            log_warn "Could not remount $boot_mp rw for backup cleanup"
            return 0
        }
    fi

    bases=$(find "$boot_mp" -maxdepth 2 -type f -name '*.bak*' 2>/dev/null \
        | sed -E 's/\.bak(\..*)?$//' \
        | sort -u)

    if [ -n "$bases" ]; then
        while IFS= read -r base; do
            [ -n "$base" ] || continue
            found=1
            dir=$(dirname "$base")
            bn=$(basename "$base")
            list=$(find "$dir" -maxdepth 1 -type f -name "${bn}.bak*" -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr \
                | awk '{print $2}')
            [ -n "$list" ] || continue
            prune=$(echo "$list" | awk -v n="$keep" 'NR>n {print}')
            if [ -n "$prune" ]; then
                while IFS= read -r f; do
                    [ -n "$f" ] || continue
                    rm -f -- "$f" || true
                    deleted=$((deleted + 1))
                done <<< "$prune"
            fi
        done <<< "$bases"
    fi

    if [ "$ro_before" = "1" ]; then
        mount -o remount,ro "$boot_mp" >/dev/null 2>&1 || true
    fi

    if [ "$found" -eq 1 ]; then
        log_info "Boot backup cleanup complete: deleted=${deleted}, keep=${keep}"
    fi
}

# Avoid spamming on very early boot
uptime_sec=$(cut -d. -f1 /proc/uptime || echo 0)
if [ "$uptime_sec" -lt "$MIN_UPTIME_SEC" ]; then
    log_warn "Uptime ${uptime_sec}s < ${MIN_UPTIME_SEC}s, skipping mark-good"
    exit 0
fi

status_json=$(rauc status --output-format=json 2>/dev/null || true)
if [ -z "$status_json" ]; then
    die "Failed to read RAUC status"
fi

booted_slot=$(echo "$status_json" | jq -r '.booted // empty')
if [ -z "$booted_slot" ]; then
    log_warn "No booted slot detected"
    exit 0
fi

slot_state=$(echo "$status_json" | jq -r --arg slot "$booted_slot" \
    '.slots[][] | select(.bootname == $slot) | .state // empty')

if [ "$slot_state" = "good" ]; then
    log_info "Booted slot already marked good"
    exit 0
fi

sys_state=$(systemctl is-system-running 2>/dev/null || true)
if [ "$sys_state" != "running" ] && [ "$sys_state" != "degraded" ]; then
    log_warn "System state is '$sys_state', skipping mark-good"
    exit 0
fi

log_info "Marking booted slot '$booted_slot' good"
if ! rauc status mark-good booted; then
    die "Failed to mark booted slot good"
fi

# After successful mark-good, prune old boot backup files (*.bak*).
prune_boot_backups
