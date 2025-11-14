#!/bin/sh
set -eu

SRC_DIR="/usr/share/iotgw/bootfiles"
BOOT_DEV="/dev/mmcblk0p1"
BOOT_MP="/boot"

log() { echo "[bootfiles-updater] $*" >&2; }

[ -d "$SRC_DIR" ] || { log "no $SRC_DIR; nothing to do"; exit 0; }

if ! mountpoint -q "$BOOT_MP"; then
    mkdir -p "$BOOT_MP"
    mount -t vfat "$BOOT_DEV" "$BOOT_MP" || { log "failed to mount $BOOT_DEV at $BOOT_MP"; exit 0; }
fi

# Try to ensure rw mount
mount -o remount,rw "$BOOT_MP" || true

updated=0
for f in boot.scr u-boot.bin splash.bmp; do
    if [ -f "$SRC_DIR/$f" ]; then
        # Only copy if different to reduce wear
        if ! cmp -s "$SRC_DIR/$f" "$BOOT_MP/$f" 2>/dev/null; then
            log "updating $BOOT_MP/$f"
            install -m 0644 "$SRC_DIR/$f" "$BOOT_MP/$f"
            updated=1
        fi
    fi
done

if [ "$updated" -eq 1 ]; then
    sync || true
fi

exit 0

