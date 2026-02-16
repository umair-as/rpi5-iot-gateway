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
