#!/bin/sh
set -eu

log() { echo "[bundle-hook] $*" >&2; }

# Determine hook type as RAUC defines it
# Canonical: RAUC passes hook name as first positional arg for slot hooks
# Fallbacks: older/other contexts export env vars
HOOK_TYPE="${1:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_HOOK_TYPE:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_SLOT_HOOK:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_SLOT_HOOK_TYPE:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_SLOT_HOOK_NAME:-}"
[ -z "$HOOK_TYPE" ] && HOOK_TYPE="${RAUC_HOOK:-}"
# Normalize variants to a single value for matching
case "$HOOK_TYPE" in
  slot-post-install) HOOK_TYPE="post-install" ;;
  slot-pre-install) HOOK_TYPE="pre-install" ;;
esac

# RAUC provides RAUC_BUNDLE_MOUNT_POINT pointing to mounted bundle content
BUNDLE_MNT="${RAUC_BUNDLE_MOUNT_POINT:-/run/rauc/mnt/bundle}"
BOOT_DEV="/dev/mmcblk0p1"
BOOT_MP="/boot"

case "${HOOK_TYPE:-}" in
  post-install)
    :
    ;;
  *)
    log "unknown or unset hook type '${HOOK_TYPE:-}' (expected post-install)"
    exit 0
    ;;
esac

ARCHIVE="${BUNDLE_MNT}/bootfiles.tar.gz"
if [ ! -r "$ARCHIVE" ]; then
  log "no bootfiles.tar.gz in bundle; skipping /boot update"
  exit 0
fi

tmpdir=$(mktemp -d /tmp/bootfiles.XXXXXX)
cleanup() { rm -rf "$tmpdir" || true; }
trap cleanup EXIT INT TERM

log "updating /boot from bundle archive"
tar -C "$tmpdir" -xzf "$ARCHIVE" || { log "failed to extract bootfiles"; exit 1; }

# Validate module/kernel release alignment if possible
MODS_DIR="$RAUC_SLOT_MOUNT_POINT/lib/modules"
mods_release=""
if [ -d "$MODS_DIR" ]; then
  mods_release=$(basename "$(ls -d "$MODS_DIR"/* 2>/dev/null | head -n1)" || true)
fi
expected_release=""
if [ -f "$tmpdir/kernel.release" ]; then
  expected_release="$(cat "$tmpdir/kernel.release" 2>/dev/null || true)"
fi
if [ -n "$expected_release" ] && [ -n "$mods_release" ] && [ "$expected_release" != "$mods_release" ]; then
  log "mismatch: expected kernel release '$expected_release' but rootfs has modules for '$mods_release'"
  exit 1
fi

# Ensure /boot is mounted
if ! mountpoint -q "$BOOT_MP"; then
  mkdir -p "$BOOT_MP"
  mount -t vfat "$BOOT_DEV" "$BOOT_MP" || { log "failed to mount $BOOT_DEV at $BOOT_MP"; exit 0; }
fi

# Try to ensure rw mount
mount -o remount,rw "$BOOT_MP" || true

updated=0
# Files we may replace in /boot
FILES="boot.scr u-boot.bin splash.bmp Image kernel_2712.img bcm2712-rpi-5-b.dtb"
for f in $FILES; do
  if [ -f "$tmpdir/$f" ]; then
    log "installing $f to /boot"
    install -m 0644 "$tmpdir/$f" "$BOOT_MP/$f"
    updated=1
  fi
done

# Overlays directory (copy present files; keep logs concise)
if [ -d "$tmpdir/overlays" ]; then
  mkdir -p "$BOOT_MP/overlays"
  overlays_copied=0
  for f in "$tmpdir"/overlays/*; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    install -m 0644 "$f" "$BOOT_MP/overlays/$bn"
    overlays_copied=$((overlays_copied + 1))
    updated=1
  done
  if [ "${overlays_copied}" -gt 0 ]; then
    log "installed ${overlays_copied} overlay file(s) to /boot/overlays"
  fi
fi

# Ensure kernel_2712.img exists for Pi5 firmware even if bundle only shipped Image
if [ ! -f "$tmpdir/kernel_2712.img" ] && [ -f "$tmpdir/Image" ]; then
  log "installing kernel_2712.img (from Image) to /boot"
  install -m 0644 "$tmpdir/Image" "$BOOT_MP/kernel_2712.img"
  updated=1
fi

if [ "$updated" -eq 1 ]; then
  sync || true
  log "boot files updated"
else
  log "boot files already up-to-date"
fi

# Prefer U-Boot chainloading when available: enforce kernel=u-boot.bin in config.txt
if [ -r "$BOOT_MP/config.txt" ] && [ -r "$BOOT_MP/u-boot.bin" ]; then
  log "ensuring config.txt boots U-Boot (kernel=u-boot.bin)"
  cp -a "$BOOT_MP/config.txt" "$BOOT_MP/config.txt.bak.$(date +%Y%m%d%H%M%S)" || true
  # Remove existing kernel= lines and append kernel=u-boot.bin
  sed -E '/^[[:space:]]*kernel=/d' "$BOOT_MP/config.txt" > "$BOOT_MP/config.txt.tmp" || cp -a "$BOOT_MP/config.txt" "$BOOT_MP/config.txt.tmp"
  printf '%s\n' "kernel=u-boot.bin" >> "$BOOT_MP/config.txt.tmp"
  mv "$BOOT_MP/config.txt.tmp" "$BOOT_MP/config.txt"
  sync || true

  # With U-Boot in charge, remove any firmware-preset root=/rauc.slot= from cmdline.txt
  if [ -r "$BOOT_MP/cmdline.txt" ]; then
    log "stripping root=/rauc.slot= from cmdline.txt (U-Boot controls root)"
    cp -a "$BOOT_MP/cmdline.txt" "$BOOT_MP/cmdline.txt.bak.$(date +%Y%m%d%H%M%S)" || true
    current=$(cat "$BOOT_MP/cmdline.txt" 2>/dev/null || echo "")
    stripped=$(printf '%s\n' "$current" \
      | sed -E 's/(^| )root=[^ ]+//g; s/(^| )rauc\.slot=[^ ]+//g' \
      | tr -s ' ' \
      | sed -E 's/^ +| +$//g')
    printf '%s\n' "$stripped" > "$BOOT_MP/cmdline.txt"
    sync || true
  fi
else
  # If we boot via firmware (not U-Boot), ensure next boot root= points to the
  # just-installed target slot by updating /boot/cmdline.txt accordingly.
  TARGET_ROOT=""
  # Prefer RAUC-provided slot device if available
  if [ -n "${RAUC_SLOT_DEVICE:-}" ]; then
    TARGET_ROOT="${RAUC_SLOT_DEVICE}"
  elif [ -n "${RAUC_SLOT_NAME:-}" ]; then
    case "${RAUC_SLOT_NAME}" in
      rootfs.0) TARGET_ROOT="/dev/mmcblk0p2" ;;
      rootfs.1) TARGET_ROOT="/dev/mmcblk0p3" ;;
    esac
  fi
  if [ -n "$TARGET_ROOT" ] && [ -r "$BOOT_MP/cmdline.txt" ]; then
    log "updating cmdline.txt root=${TARGET_ROOT} for next boot"
    cp -a "$BOOT_MP/cmdline.txt" "$BOOT_MP/cmdline.txt.bak.$(date +%Y%m%d%H%M%S)" || true
    current=$(cat "$BOOT_MP/cmdline.txt" 2>/dev/null || echo "")
    stripped=$(printf '%s\n' "$current" | sed -E 's/(^| )root=[^ ]+//g' | tr -s ' ' | sed -E 's/^ +| +$//g')
    if [ -n "$stripped" ]; then
      echo "$stripped root=${TARGET_ROOT}" > "$BOOT_MP/cmdline.txt"
    else
      echo "root=${TARGET_ROOT}" > "$BOOT_MP/cmdline.txt"
    fi
    sync || true
  fi
fi

exit 0
