#!/usr/bin/env bash
set -Eeuo pipefail

LOG_TAG="iotgw-encstore"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

on_err() { die "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

# shellcheck disable=SC1091
[ -f /etc/default/iotgw-encrypted-store ] && . /etc/default/iotgw-encrypted-store

STORE_DIR="${STORE_DIR:-/data/encrypted-store}"
IMAGE_PATH="${IMAGE_PATH:-${STORE_DIR}/store.luks2.img}"
MAPPER_NAME="${MAPPER_NAME:-igwencstore}"
SIZE_MIB="${SIZE_MIB:-1024}"
RECOVERY_KEY_FILE="${RECOVERY_KEY_FILE:-${STORE_DIR}/recovery.key}"
TPM2_DEVICE="${TPM2_DEVICE:-auto}"
TPM2_PCRS="${TPM2_PCRS:-7}"
MAPPER_PATH="/dev/mapper/${MAPPER_NAME}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

is_mapped() {
    [ -e "$MAPPER_PATH" ]
}

is_luks() {
    cryptsetup isLuks "$IMAGE_PATH" >/dev/null 2>&1
}

has_tpm_token() {
    cryptsetup luksDump "$IMAGE_PATH" 2>/dev/null | grep -q 'systemd-tpm2'
}

ensure_recovery_key() {
    if [ -f "$RECOVERY_KEY_FILE" ]; then
        return 0
    fi
    umask 077
    head -c 48 /dev/urandom | base64 > "$RECOVERY_KEY_FILE"
    chmod 600 "$RECOVERY_KEY_FILE"
    log "created recovery key ${RECOVERY_KEY_FILE}"
}

ensure_luks_image() {
    if [ ! -f "$IMAGE_PATH" ]; then
        log "creating sparse image ${IMAGE_PATH} (${SIZE_MIB} MiB)"
        truncate -s "${SIZE_MIB}M" "$IMAGE_PATH"
    fi

    if ! is_luks; then
        log "formatting image as LUKS2"
        cryptsetup luksFormat --type luks2 --batch-mode --key-file "$RECOVERY_KEY_FILE" "$IMAGE_PATH"
    fi
}

ensure_tpm_token() {
    if has_tpm_token; then
        return 0
    fi

    log "enrolling TPM token (device=${TPM2_DEVICE}, pcrs=${TPM2_PCRS})"
    systemd-cryptenroll "$IMAGE_PATH" \
        --unlock-key-file="$RECOVERY_KEY_FILE" \
        --tpm2-device="$TPM2_DEVICE" \
        --tpm2-pcrs="$TPM2_PCRS"
}

ensure_mapper() {
    if is_mapped; then
        return 0
    fi
    cryptsetup open "$IMAGE_PATH" "$MAPPER_NAME" --key-file "$RECOVERY_KEY_FILE"
    log "opened mapper ${MAPPER_PATH}"
}

ensure_ext4() {
    if blkid "$MAPPER_PATH" | grep -q 'TYPE="ext4"'; then
        return 0
    fi
    mkfs.ext4 -F -L dataenc "$MAPPER_PATH" >/dev/null
    log "created ext4 filesystem on ${MAPPER_PATH}"
}

main() {
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    [ -d /data ] || die "/data is not available"
    [ -c /dev/tpmrm0 ] || die "/dev/tpmrm0 not found"

    need_cmd cryptsetup
    need_cmd systemd-cryptenroll
    need_cmd mkfs.ext4
    need_cmd blkid
    need_cmd base64
    need_cmd head
    need_cmd truncate

    mkdir -p "$STORE_DIR"
    chmod 0700 "$STORE_DIR" || true

    ensure_recovery_key
    ensure_luks_image
    ensure_tpm_token
    ensure_mapper
    ensure_ext4

    log "setup complete for ${IMAGE_PATH} -> ${MAPPER_PATH}"
}

main "$@"
