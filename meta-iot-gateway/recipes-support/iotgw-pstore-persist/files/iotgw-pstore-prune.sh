#!/usr/bin/env bash
set -euo pipefail

PSTORE_DIR="/data/crash/pstore"
MAX_FILES="${IOTGW_PSTORE_MAX_FILES:-20}"
MAX_BYTES="${IOTGW_PSTORE_MAX_BYTES:-104857600}"

log() {
    echo "[iotgw-pstore-prune] $*"
}

[ -d "${PSTORE_DIR}" ] || exit 0

# Compress older plain-text records; keep newest few uncompressed for quick triage.
find "${PSTORE_DIR}" -maxdepth 1 -type f \
    ! -name "*.xz" \
    ! -name "*.gz" \
    ! -name ".keep" \
    -printf '%T@ %p\n' | sort -nr | awk 'NR>4 {print $2}' | while read -r f; do
    [ -f "$f" ] || continue
    xz -T0 -f "$f" || true
done

prune_by_count() {
    local total
    total="$(find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" | wc -l)"
    if [ "${total}" -le "${MAX_FILES}" ]; then
        return 0
    fi
    find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" -printf '%T@ %p\n' \
        | sort -n | head -n "$((total - MAX_FILES))" | awk '{print $2}' | while read -r f; do
            rm -f "$f"
        done
}

prune_by_size() {
    local size
    size="$(du -sb "${PSTORE_DIR}" | awk '{print $1}')"
    while [ "${size}" -gt "${MAX_BYTES}" ]; do
        oldest="$(find "${PSTORE_DIR}" -maxdepth 1 -type f ! -name ".keep" -printf '%T@ %p\n' | sort -n | head -n1 | awk '{print $2}')"
        [ -n "${oldest}" ] || break
        rm -f "${oldest}"
        size="$(du -sb "${PSTORE_DIR}" | awk '{print $1}')"
    done
}

prune_by_count
prune_by_size

log "retention applied (max_files=${MAX_FILES}, max_bytes=${MAX_BYTES})"
