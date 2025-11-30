#!/usr/bin/env bash
# Grow /data partition to consume remaining card space with robust logging

set -Eeuo pipefail

STAMP="/var/lib/rauc-grow-done"
LOG_TAG="rauc-grow"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() { log "❌ ERROR: $*"; exit 1; }

on_err() { die "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

# Resolve the data partition by label to be resilient across devices
resolve_data_part() {
    # Prefer by-label symlink
    if [ -e /dev/disk/by-label/data ]; then
        readlink -f /dev/disk/by-label/data
        return 0
    fi
    # Fallback: search lsblk for label "data"
    lsblk -rno KNAME,LABEL | awk '$2=="data"{print "/dev/"$1; found=1} END{exit (found?0:1)}'
}

already_done() {
    [ -f "$STAMP" ]
}

main() {
    if already_done; then
        log "✓ stamp present; nothing to do"
        return 0
    fi

    command -v parted >/dev/null 2>&1 || die "parted not installed"
    command -v resize2fs >/dev/null 2>&1 || die "resize2fs not installed"

    DATA_PART=$(resolve_data_part) || die "could not resolve data partition by label 'data'"
    [ -b "$DATA_PART" ] || die "not a block device: $DATA_PART"

    # Derive parent disk and partition number (handles mmcblk0p4, nvme0n1p4, sda4)
    base=$(basename "$DATA_PART")
    case "$base" in
        mmcblk*p*[0-9]) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        nvme*n*p[0-9]*) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        *[0-9])         DISK="/dev/${base%[0-9]*}"; PART_NUM=${base##*[!0-9]} ;;
        *) die "cannot parse disk/partition from $base" ;;
    esac

    log "🔍 target partition: $DATA_PART (disk=$DISK part=$PART_NUM)"

    # Best-effort rescan before resize
    partprobe "$DISK" 2>/dev/null || true

    # Attempt to grow the partition to 100%. If already at max, just continue.
    RESIZE_ERR=$(mktemp)
    if parted -s "$DISK" resizepart "$PART_NUM" 100% 2>"$RESIZE_ERR"; then
        log "📏 resized partition $PART_NUM to 100%"
    else
        if grep -qi "cannot be grown\|already at maximum size\|out of range" "$RESIZE_ERR" 2>/dev/null; then
            log "✓ partition appears already at maximum size; continuing"
        else
            cat "$RESIZE_ERR" >&2 || true
            die "parted resizepart failed"
        fi
    fi
    rm -f "$RESIZE_ERR" || true

    # Let the kernel notice the new partition size
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # Grow the filesystem (ext4 supports online grow)
    log "💾 growing filesystem on $DATA_PART"
    # Run filesystem check first (required if partition was previously resized)
    e2fsck -f -p "$DATA_PART" 1>&2 || true
    resize2fs "$DATA_PART" 1>&2

    touch "$STAMP"
    log "✅ growth complete"
}

main "$@"

