#!/usr/bin/env bash
set -euo pipefail

PERSIST_ROOT="/data/crash/pstore"
TARGET_DIR="/var/lib/systemd/pstore"

log() {
    echo "[iotgw-pstore-persist] $*"
}

if ! mountpoint -q /data; then
    log "ERROR: /data is not mounted"
    exit 1
fi

install -d -m 0700 "${PERSIST_ROOT}"
install -d -m 0755 "$(dirname "${TARGET_DIR}")"
install -d -m 0700 "${TARGET_DIR}"

source_now="$(findmnt -n -o SOURCE --target "${TARGET_DIR}" 2>/dev/null || true)"
if [ "${source_now}" = "${PERSIST_ROOT}" ]; then
    log "bind mount already active"
    exit 0
fi

if mountpoint -q "${TARGET_DIR}"; then
    umount "${TARGET_DIR}"
fi

mount --bind "${PERSIST_ROOT}" "${TARGET_DIR}"
mount -o remount,bind,rw,nodev,nosuid,noexec "${TARGET_DIR}" || true
log "bound ${PERSIST_ROOT} -> ${TARGET_DIR}"
