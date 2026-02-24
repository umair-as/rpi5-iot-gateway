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
Usage: iotgw-rauc-install [-n|--n|--dry-run] <bundle|url> [rauc install args...]

Wrapper for `rauc install` that temporarily remounts /boot read-write so
fw_setenv-backed bootloader updates succeed, then restores prior mount state.
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

if [ "${DRY_RUN}" -eq 1 ]; then
    audit "dry-run bundle='$*' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
    audit "dry-run would remount ${BOOT_MP} rw"
    audit "dry-run would run: rauc install $*"
    INSTALL_RC=0
    exit 0
fi

audit "starting bundle='$*' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
mount -o remount,rw "${BOOT_MP}" || die "failed to remount ${BOOT_MP} rw"
REMOUNTED_RW=1
audit "remounted /boot rw"

audit "running rauc install"
if rauc install "$@"; then
    INSTALL_RC=0
    audit "rauc install succeeded"
else
    INSTALL_RC=$?
    audit "rauc install failed rc=${INSTALL_RC}"
    exit "${INSTALL_RC}"
fi
