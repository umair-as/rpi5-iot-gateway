#!/bin/sh
set -eu

SRC_DIR="/usr/share/iotgw/bootfiles"
BOOT_DEV="/dev/mmcblk0p1"
BOOT_MP="/boot"

log_info() { echo "⚙️  [bootfiles-updater] $*" >&2; }
log_warn() { echo "⚠️  [bootfiles-updater] $*" >&2; }
log_error(){ echo "❌ [bootfiles-updater] $*" >&2; }
die()      { log_error "$*"; exit 1; }
on_err()   { log_error "failed at line ${1:-?}"; }
trap 'on_err $LINENO' ERR

[ -d "$SRC_DIR" ] || { log_info "no $SRC_DIR; nothing to do"; exit 0; }

for cmd in mountpoint mount install cmp sync; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

if ! mountpoint -q "$BOOT_MP"; then
    mkdir -p "$BOOT_MP"
    mount -t vfat "$BOOT_DEV" "$BOOT_MP" || die "failed to mount $BOOT_DEV at $BOOT_MP"
fi

# Try to ensure rw mount
if ! mount -o remount,rw "$BOOT_MP"; then
    log_warn "failed to remount $BOOT_MP read-write"
fi

updated=0
for f in boot.scr u-boot.bin splash.bmp; do
    if [ -f "$SRC_DIR/$f" ]; then
        # Only copy if different to reduce wear
        if ! cmp -s "$SRC_DIR/$f" "$BOOT_MP/$f" 2>/dev/null; then
            log_info "updating $BOOT_MP/$f"
            install -m 0644 "$SRC_DIR/$f" "$BOOT_MP/$f"
            updated=1
        fi
    fi
done

if [ "$updated" -eq 1 ]; then
    sync || true
fi

exit 0
