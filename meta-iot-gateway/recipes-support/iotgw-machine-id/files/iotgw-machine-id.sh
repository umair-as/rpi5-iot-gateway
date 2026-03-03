#!/usr/bin/env bash
# Persist machine-id under /data and bind it to /etc/machine-id for RO rootfs.

set -euo pipefail

PERSIST_PATH="/data/machine-id"
ETC_PATH="/etc/machine-id"

log() {
    echo "[iotgw-machine-id] $*"
}

read_first_line() {
    sed -n '1p' "$1" 2>/dev/null | tr -d '[:space:]'
}

is_valid_machine_id() {
    [[ "$1" =~ ^[0-9a-f]{32}$ ]]
}

generate_machine_id() {
    local mid
    mid=""

    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        mid="$(systemd-machine-id-setup --print 2>/dev/null | tail -n1 | tr -d '[:space:]' || true)"
    fi
    if ! is_valid_machine_id "${mid}"; then
        mid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | tr -d '[:space:]' || true)"
    fi
    if ! is_valid_machine_id "${mid}"; then
        log "ERROR: unable to generate valid machine-id"
        return 1
    fi
    printf '%s\n' "${mid}"
}

if ! mountpoint -q /data; then
    log "ERROR: /data is not mounted"
    exit 1
fi

mid=""
if [ -r "${PERSIST_PATH}" ]; then
    mid="$(read_first_line "${PERSIST_PATH}")"
fi

if ! is_valid_machine_id "${mid}"; then
    mid="$(generate_machine_id)"
    install -d -m 0755 /data
    printf '%s\n' "${mid}" > "${PERSIST_PATH}"
    chmod 0444 "${PERSIST_PATH}"
    log "persisted machine-id at ${PERSIST_PATH}"
else
    log "using existing persisted machine-id"
fi

if [ "$(findmnt -n -o SOURCE "${ETC_PATH}" 2>/dev/null || true)" != "${PERSIST_PATH}" ]; then
    mount --bind "${PERSIST_PATH}" "${ETC_PATH}"
    mount -o remount,bind,ro "${ETC_PATH}" || true
fi

log "machine-id source: $(findmnt -n -o SOURCE "${ETC_PATH}" 2>/dev/null || echo unknown)"
