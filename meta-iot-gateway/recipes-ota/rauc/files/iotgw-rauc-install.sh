#!/usr/bin/env bash
set -euo pipefail

BOOT_MP="/boot"
MOUNTED_BEFORE=0
RO_BEFORE=0
MOUNTED_BY_US=0
REMOUNTED_RW=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INSTALL_RC=0
DRY_RUN=0
DIRECT_MODE=0
DISPATCHED_MODE=0
BOOT_RW_REQUIRED=1

log() { printf '[iotgw-rauc-install] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
audit() {
    local msg="$*"
    log "run=${RUN_ID} ${msg}"
    if command -v logger >/dev/null 2>&1; then
        logger -t iotgw-rauc-install "run=${RUN_ID} ${msg}" || true
    fi
}

usage() {
    cat >&2 <<'EOF'
Usage: iotgw-rauc-install [--direct] [--no-systemd-run] [-n|--n|--dry-run] <bundle|url> [rauc install args...]

Wrapper for `rauc install` that temporarily remounts /boot read-write so
fw_setenv-backed bootloader updates succeed, then restores prior mount state.
If `/etc/fw_env.config` does not point into `/boot`, remount is skipped.

By default, it dispatches itself through `systemd-run` for consistent
privilege/mount namespace semantics on hardened systems.
EOF
    exit 2
}

restore_mount_state() {
    local rc="$?"

    if [ "${MOUNTED_BY_US}" -eq 1 ]; then
        if [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] && mountpoint -q "${BOOT_MP}"; then
            mount -o remount,ro "${BOOT_MP}" || true
            audit "restored /boot to ro (wrapper-mounted case)"
        fi
        umount "${BOOT_MP}" || true
        audit "unmounted /boot (wrapper-mounted case), install_rc=${INSTALL_RC}, exit_rc=${rc}"
        exit "${rc}"
    fi

    if [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] && mountpoint -q "${BOOT_MP}"; then
        mount -o remount,ro "${BOOT_MP}" || true
        audit "restored /boot to ro"
    fi

    audit "completed install_rc=${INSTALL_RC}, exit_rc=${rc}"
    exit "${rc}"
}

trap restore_mount_state EXIT INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --direct)
            DIRECT_MODE=1
            shift
            ;;
        --no-systemd-run)
            DISPATCHED_MODE=1
            shift
            ;;
        -n|--n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -ge 1 ] || usage
command -v rauc >/dev/null 2>&1 || die "rauc command not found"
command -v mountpoint >/dev/null 2>&1 || die "mountpoint command not found"
command -v findmnt >/dev/null 2>&1 || die "findmnt command not found"

if [ -r /etc/fw_env.config ]; then
    fw_env_target="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' /etc/fw_env.config || true)"
    case "${fw_env_target}" in
        /boot/*)
            BOOT_RW_REQUIRED=1
            ;;
        *)
            BOOT_RW_REQUIRED=0
            ;;
    esac
fi

# Prefer executing from systemd manager context to avoid hardened SSH session
# namespace/capability differences from rauc.service.
if [ "${DIRECT_MODE}" -eq 0 ] && [ "${DISPATCHED_MODE}" -eq 0 ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        unit="iotgw-rauc-install-${RUN_ID}"
        audit "dispatching via systemd-run unit=${unit}"
        if systemd-run \
            --quiet \
            --wait \
            --collect \
            --pipe \
            --unit "${unit}" \
            /usr/sbin/iotgw-rauc-install --direct "$@"; then
            INSTALL_RC=0
            audit "systemd-run install succeeded"
            exit 0
        else
            INSTALL_RC=$?
            audit "systemd-run install failed rc=${INSTALL_RC}"
            exit "${INSTALL_RC}"
        fi
    fi
    audit "systemd-run not available; continuing direct"
fi

if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
    if mountpoint -q "${BOOT_MP}"; then
        MOUNTED_BEFORE=1
    else
        mount "${BOOT_MP}" || die "failed to mount ${BOOT_MP}"
        MOUNTED_BY_US=1
    fi

    if [ "${MOUNTED_BEFORE}" -eq 1 ] || [ "${MOUNTED_BY_US}" -eq 1 ]; then
        if findmnt -no OPTIONS "${BOOT_MP}" | grep -qw ro; then
            RO_BEFORE=1
        fi
    fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    audit "dry-run bundle='$*' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
    if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
        audit "dry-run would remount ${BOOT_MP} rw"
    else
        audit "dry-run: /boot remount not required (fw_env.config target='${fw_env_target:-unknown}')"
    fi
    audit "dry-run would run: rauc install $*"
    INSTALL_RC=0
    exit 0
fi

audit "starting bundle='$*' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
    mount -o remount,rw "${BOOT_MP}" || die "failed to remount ${BOOT_MP} rw"
    REMOUNTED_RW=1
    audit "remounted /boot rw"
else
    audit "/boot remount skipped (fw_env.config target='${fw_env_target:-unknown}')"
fi

audit "running rauc install"
if rauc install "$@"; then
    INSTALL_RC=0
    audit "rauc install succeeded"
else
    INSTALL_RC=$?
    audit "rauc install failed rc=${INSTALL_RC}"
    exit "${INSTALL_RC}"
fi
