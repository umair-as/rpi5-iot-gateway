#!/usr/bin/env bash
# Grow /data partition to consume remaining card space with robust logging

set -Eeuo pipefail

STAMP="/boot/.rauc-grow-done"
LOG_TAG="rauc-grow"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

on_err() { die "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

# Resolve the data partition. Prefer the stable rauc-slot symlink (appears at
# udev-trigger time, no udev-settle needed), then by-label (requires blkid
# probe), then lsblk label scan as last resort.
resolve_data_part() {
    if [ -e /dev/disk/by-rauc-slot/data ]; then
        readlink -f /dev/disk/by-rauc-slot/data
        return 0
    fi
    if [ -e /dev/disk/by-label/data ]; then
        readlink -f /dev/disk/by-label/data
        return 0
    fi
    # Fallback: search lsblk for label "data"
    lsblk -rno KNAME,LABEL | awk '$2=="data"{print "/dev/"$1; found=1} END{exit (found?0:1)}'
}

# Poll until resolve_data_part succeeds or we time out (40 x 250 ms = 10 s).
wait_for_data_part() {
    local i=0
    while [ $i -lt 40 ]; do
        if resolve_data_part 2>/dev/null; then
            return 0
        fi
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

already_done() {
    [ -f "$STAMP" ]
}

run_parted_resize() {
    local disk="$1"
    local part_num="$2"
    local err_file="$3"

    if parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"; then
        return 0
    fi

    # Retry once after re-reading partition table.
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    if parted -s "$disk" resizepart "$part_num" 100% 2>"$err_file"; then
        return 0
    fi

    return 1
}

main() {
    if already_done; then
        log "stamp present; nothing to do"
        return 0
    fi

    command -v parted >/dev/null 2>&1 || die "parted not installed"
    command -v resize2fs >/dev/null 2>&1 || die "resize2fs not installed"
    command -v e2fsck >/dev/null 2>&1 || die "e2fsck not installed"
    command -v lsblk >/dev/null 2>&1 || die "lsblk not installed"
    command -v partprobe >/dev/null 2>&1 || die "partprobe not installed"
    command -v udevadm >/dev/null 2>&1 || die "udevadm not installed"
    command -v sgdisk >/dev/null 2>&1 || die "sgdisk not installed"

    DATA_PART=$(wait_for_data_part) || die "could not resolve data partition (by-rauc-slot, by-label, or lsblk)"
    [ -b "$DATA_PART" ] || die "not a block device: $DATA_PART"

    # Derive parent disk and partition number (handles mmcblk0p5, nvme0n1p5, sda5)
    base=$(basename "$DATA_PART")
    case "$base" in
        mmcblk*p*[0-9]) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        nvme*n*p[0-9]*) DISK="/dev/${base%p*}"; PART_NUM=${base##*p} ;;
        *[0-9])         DISK="/dev/${base%[0-9]*}"; PART_NUM=${base##*[!0-9]} ;;
        *) die "cannot parse disk/partition from $base" ;;
    esac

    log "target partition: $DATA_PART (disk=$DISK part=$PART_NUM)"

    # Best-effort rescan before resize
    partprobe "$DISK" 2>/dev/null || true

    # Relocate GPT backup table to disk end (required for larger media than image).
    sgdisk -e "$DISK" >/dev/null 2>&1 || die "failed to relocate GPT backup header on $DISK"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    # Attempt to grow the partition to 100%. If already at max, just continue.
    RESIZE_ERR=$(mktemp)
    if run_parted_resize "$DISK" "$PART_NUM" "$RESIZE_ERR"; then
        log "resized partition $PART_NUM to 100%"
    else
        if grep -qi "cannot be grown\|already at maximum size\|out of range" "$RESIZE_ERR" 2>/dev/null; then
            log "partition appears already at maximum size; continuing"
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
    log "growing filesystem on $DATA_PART"
    # Run filesystem check first (required if partition was previously resized)
    e2fsck -f -p "$DATA_PART" 1>&2 || true
    resize2fs "$DATA_PART" 1>&2

    touch "$STAMP"
    log "growth complete"
}

main "$@"
