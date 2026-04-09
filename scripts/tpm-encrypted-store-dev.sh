#!/usr/bin/env bash
set -euo pipefail

# Dev helper: create a loopback LUKS2 "encrypted store" under /data and enroll
# a TPM2 token via systemd-cryptenroll.
#
# Default behavior uses PCR 7 (systemd default), but current RPi5 TPM PCR
# measurements are all-zero in this project, so this policy is effectively
# unenforced until measured-boot policy is finalized.
#
# Example:
#   sudo bash scripts/tpm-encrypted-store-dev.sh
#   sudo bash scripts/tpm-encrypted-store-dev.sh --size-mib 512
#   sudo TPM2_PCRS="7" bash scripts/tpm-encrypted-store-dev.sh

STORE_DIR="${STORE_DIR:-/data/encrypted-store}"
IMAGE_PATH="${IMAGE_PATH:-$STORE_DIR/store.luks2.img}"
MAP_NAME="${MAP_NAME:-igwencstore}"
MOUNT_POINT="${MOUNT_POINT:-$STORE_DIR/mnt}"
SIZE_MIB="${SIZE_MIB:-1024}"
RECOVERY_KEY_FILE="${RECOVERY_KEY_FILE:-$STORE_DIR/recovery.key}"
TPM2_DEVICE="${TPM2_DEVICE:-auto}"
TPM2_PCRS="${TPM2_PCRS:-7}"
FORCE_RECREATE=0

usage() {
    cat <<EOF
Usage: $0 [--size-mib N] [--force-recreate]

Options:
  --size-mib N        Image size in MiB (default: ${SIZE_MIB})
  --force-recreate    Delete existing image/mapping and recreate from scratch

Environment overrides:
  STORE_DIR, IMAGE_PATH, MAP_NAME, MOUNT_POINT, RECOVERY_KEY_FILE,
  TPM2_DEVICE, TPM2_PCRS
EOF
}

log() { printf '[enc-store] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --size-mib)
                shift
                [ "${1:-}" ] || die "--size-mib requires a value"
                SIZE_MIB="$1"
                ;;
            --force-recreate)
                FORCE_RECREATE=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
        shift
    done
}

cleanup_mount_if_needed() {
    if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
        log "unmounting existing mount: $MOUNT_POINT"
        umount "$MOUNT_POINT"
    fi
}

close_mapper_if_needed() {
    if [ -e "/dev/mapper/$MAP_NAME" ]; then
        log "closing existing mapper: $MAP_NAME"
        cryptsetup close "$MAP_NAME"
    fi
}

create_recovery_key() {
    if [ -f "$RECOVERY_KEY_FILE" ]; then
        log "recovery key already exists: $RECOVERY_KEY_FILE"
        return 0
    fi
    umask 077
    head -c 48 /dev/urandom | base64 > "$RECOVERY_KEY_FILE"
    chmod 600 "$RECOVERY_KEY_FILE"
    log "created recovery key: $RECOVERY_KEY_FILE"
}

format_if_needed() {
    if cryptsetup isLuks "$IMAGE_PATH" >/dev/null 2>&1; then
        log "existing LUKS container detected: $IMAGE_PATH"
        return 0
    fi
    log "formatting LUKS2 image"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$RECOVERY_KEY_FILE" "$IMAGE_PATH"
}

enroll_tpm_if_needed() {
    if cryptsetup luksDump "$IMAGE_PATH" | grep -q 'systemd-tpm2'; then
        log "TPM token already present in LUKS header"
        return 0
    fi

    log "enrolling TPM token (device=${TPM2_DEVICE}, pcrs='${TPM2_PCRS}')"
    enroll_args=(
        "$IMAGE_PATH"
        "--unlock-key-file=$RECOVERY_KEY_FILE"
        "--tpm2-device=$TPM2_DEVICE"
    )
    if [ -n "$TPM2_PCRS" ]; then
        enroll_args+=("--tpm2-pcrs=$TPM2_PCRS")
    fi

    systemd-cryptenroll "${enroll_args[@]}"
}

open_mapper() {
    if [ ! -e "/dev/mapper/$MAP_NAME" ]; then
        log "opening mapper: $MAP_NAME"
        cryptsetup open "$IMAGE_PATH" "$MAP_NAME" --key-file "$RECOVERY_KEY_FILE"
    fi
}

make_fs_if_needed() {
    if blkid "/dev/mapper/$MAP_NAME" | grep -q 'TYPE="ext4"'; then
        log "ext4 already present on mapper"
        return 0
    fi
    log "creating ext4 filesystem on mapper"
    mkfs.ext4 -F -L dataenc "/dev/mapper/$MAP_NAME" >/dev/null
}

mount_store() {
    mkdir -p "$MOUNT_POINT"
    if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
        log "already mounted: $MOUNT_POINT"
        return 0
    fi
    log "mounting encrypted store"
    mount "/dev/mapper/$MAP_NAME" "$MOUNT_POINT"
}

write_marker() {
    local marker="$MOUNT_POINT/README.encrypted-store.txt"
    if [ ! -f "$marker" ]; then
        cat > "$marker" <<EOF
IoT Gateway dev encrypted store
image: $IMAGE_PATH
mapper: /dev/mapper/$MAP_NAME
created_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
    fi
}

main() {
    parse_args "$@"

    [ "$(id -u)" -eq 0 ] || die "run as root"
    require_cmd cryptsetup
    require_cmd systemd-cryptenroll
    require_cmd mkfs.ext4
    require_cmd mount
    require_cmd findmnt
    require_cmd blkid
    require_cmd head
    require_cmd base64

    mkdir -p "$STORE_DIR"

    if [ "$FORCE_RECREATE" -eq 1 ]; then
        cleanup_mount_if_needed
        close_mapper_if_needed
        rm -f "$IMAGE_PATH"
        log "removed existing image (force mode)"
    fi

    if [ ! -f "$IMAGE_PATH" ]; then
        log "creating sparse image: $IMAGE_PATH (${SIZE_MIB} MiB)"
        truncate -s "${SIZE_MIB}M" "$IMAGE_PATH"
    fi

    create_recovery_key
    format_if_needed
    enroll_tpm_if_needed
    open_mapper
    make_fs_if_needed
    mount_store
    write_marker

    log "done"
    log "image: $IMAGE_PATH"
    log "mapper: /dev/mapper/$MAP_NAME"
    log "mount : $MOUNT_POINT"
    log "key   : $RECOVERY_KEY_FILE (dev-only; back it up before experiments)"
}

main "$@"
