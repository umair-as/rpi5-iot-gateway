#!/bin/sh
set -eu

# Logging functions with descriptive emojis for better visibility
log_info()    { echo "📦 [bundle-hook] $*" >&2; }
log_success() { echo "✅ [bundle-hook] $*" >&2; }
log_update()  { echo "📝 [bundle-hook] $*" >&2; }
log_error()   { echo "❌ [bundle-hook] $*" >&2; }
log_warn()    { echo "⚠️  [bundle-hook] $*" >&2; }
log_clean()   { echo "🧹 [bundle-hook] $*" >&2; }
log_install() { echo "⚙️  [bundle-hook] $*" >&2; }
log_check()   { echo "🔍 [bundle-hook] $*" >&2; }
log_skip()    { echo "⏭️  [bundle-hook] $*" >&2; }
# Backward compatibility
log() { log_info "$*"; }

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
    log_info "Hook type: post-install"
    ;;
  *)
    log_warn "Unknown or unset hook type '${HOOK_TYPE:-}' (expected post-install)"
    exit 0
    ;;
esac

ARCHIVE="${BUNDLE_MNT}/bootfiles.tar.gz"
if [ ! -r "$ARCHIVE" ]; then
  log_skip "No bootfiles.tar.gz in bundle; skipping /boot update"
  exit 0
fi

tmpdir=$(mktemp -d /tmp/bootfiles.XXXXXX)
cleanup() { rm -rf "$tmpdir" || true; }
trap cleanup EXIT INT TERM

log_install "Extracting bootfiles from bundle archive..."
tar -C "$tmpdir" -xzf "$ARCHIVE" || { log_error "Failed to extract bootfiles"; exit 1; }

# Validate module/kernel release alignment if possible
log_check "Validating kernel/module version alignment..."
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
  log_error "Kernel/module mismatch: expected '$expected_release' but rootfs has modules for '$mods_release'"
  exit 1
fi
if [ -n "$expected_release" ] && [ -n "$mods_release" ]; then
  log_success "Kernel release validation passed: $expected_release"
fi

# Ensure /boot is mounted
log_check "Checking /boot mount status..."
if ! mountpoint -q "$BOOT_MP"; then
  log_install "Mounting $BOOT_DEV at $BOOT_MP..."
  mkdir -p "$BOOT_MP"
  mount -t vfat "$BOOT_DEV" "$BOOT_MP" || { log_error "Failed to mount $BOOT_DEV at $BOOT_MP"; exit 0; }
else
  log_success "/boot is already mounted"
fi

# Try to ensure rw mount
mount -o remount,rw "$BOOT_MP" || true

updated=0
# Files we may replace in /boot
FILES="boot.scr u-boot.bin splash.bmp Image kernel_2712.img bcm2712-rpi-5-b.dtb"
for f in $FILES; do
  if [ -f "$tmpdir/$f" ]; then
    log_install "Installing $f to /boot"
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
    log_install "Installed ${overlays_copied} overlay file(s) to /boot/overlays"
  fi
fi

# Ensure kernel_2712.img exists for Pi5 firmware even if bundle only shipped Image
if [ ! -f "$tmpdir/kernel_2712.img" ] && [ -f "$tmpdir/Image" ]; then
  log_install "Installing kernel_2712.img (from Image) to /boot"
  install -m 0644 "$tmpdir/Image" "$BOOT_MP/kernel_2712.img"
  updated=1
fi

if [ "$updated" -eq 1 ]; then
  sync || true
  log_success "Boot files updated successfully"
else
  log_skip "Boot files already up-to-date"
fi

MAX_BACKUPS="${MAX_BOOT_BACKUPS:-3}"

# Helper: prune backups, keep newest N matching pattern <file>.bak.*
prune_backups() {
  f="$1"; n="$2"
  dir=$(dirname "$f"); base=$(basename "$f")
  # Newest first
  set +e
  list=$(ls -1t "$dir/${base}.bak."* 2>/dev/null)
  rc=$?
  set -e
  [ $rc -ne 0 ] && return 0
  # Delete everything beyond first N and report count
  to_prune=$(echo "$list" | awk 'NR>n {print}' n="$n" | wc -l | awk '{print $1}')
  if [ "$to_prune" -gt 0 ]; then
    echo "$list" | awk 'NR>n {print}' n="$n" | xargs -n1 -- rm -f --
    log_clean "Pruned ${to_prune} old backups for ${base}, kept latest ${n}"
  fi
}

# Prefer U-Boot chainloading when available: enforce kernel=u-boot.bin in config.txt
if [ -r "$BOOT_MP/config.txt" ] && [ -r "$BOOT_MP/u-boot.bin" ]; then
  log_check "Checking U-Boot configuration in config.txt..."
  # Compute prospective new config (proper newlines, no literal \n)
  tmpcfg="$BOOT_MP/config.txt.tmp"
  sed -E '/^[[:space:]]*kernel=/d' "$BOOT_MP/config.txt" > "$tmpcfg" || cp -a "$BOOT_MP/config.txt" "$tmpcfg"
  echo "kernel=u-boot.bin" >> "$tmpcfg"
  # Only change if different
  if ! cmp -s "$tmpcfg" "$BOOT_MP/config.txt"; then
    log_update "Updating config.txt to boot U-Boot (kernel=u-boot.bin)"
    bk="$BOOT_MP/config.txt.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$BOOT_MP/config.txt" "$bk" || true
    prune_backups "$BOOT_MP/config.txt" "$MAX_BACKUPS"
    mv "$tmpcfg" "$BOOT_MP/config.txt"
    sync || true
  else
    rm -f "$tmpcfg" || true
    log_success "config.txt already set for U-Boot; no change"
  fi

  # Ensure Raspberry Pi firmware splash is disabled (prefer U-Boot splash)
  if [ -r "$BOOT_MP/config.txt" ]; then
    log_check "Ensuring disable_splash=1 in config.txt..."
    tmpcfg="$BOOT_MP/config.txt.tmp"
    # Drop any existing disable_splash lines (commented or not) and append desired setting
    sed -E '/^[[:space:]]*#?[[:space:]]*disable_splash[[:space:]]*=/d' "$BOOT_MP/config.txt" > "$tmpcfg" || cp -a "$BOOT_MP/config.txt" "$tmpcfg"
    echo "disable_splash=1" >> "$tmpcfg"
    if ! cmp -s "$tmpcfg" "$BOOT_MP/config.txt"; then
      log_update "Setting disable_splash=1 in config.txt"
      bk="$BOOT_MP/config.txt.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$BOOT_MP/config.txt" "$bk" || true
      prune_backups "$BOOT_MP/config.txt" "$MAX_BACKUPS"
      mv "$tmpcfg" "$BOOT_MP/config.txt"
      sync || true
    else
      rm -f "$tmpcfg" || true
      log_success "disable_splash already set; no change"
    fi
  fi

  # With U-Boot in charge (and config.txt actually set), remove any firmware-preset root=/rauc.slot=
  if [ -r "$BOOT_MP/cmdline.txt" ] && grep -Eq '^[[:space:]]*kernel[[:space:]]*=[[:space:]]*u-boot\.bin[[:space:]]*$' "$BOOT_MP/config.txt"; then
    log_check "Checking cmdline.txt for U-Boot compatibility..."
    current="$(cat "$BOOT_MP/cmdline.txt" 2>/dev/null || echo "")"
    stripped=$(printf '%s\n' "$current" \
      | sed -E 's/(^| )root=[^ ]+//g; s/(^| )rauc\.slot=[^ ]+//g' \
      | tr -s ' ' \
      | sed -E 's/^ +| +$//g')
    if [ "${current}" != "${stripped}" ]; then
      log_update "Stripping root=/rauc.slot= from cmdline.txt (U-Boot controls root)"
      bk="$BOOT_MP/cmdline.txt.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$BOOT_MP/cmdline.txt" "$bk" || true
      prune_backups "$BOOT_MP/cmdline.txt" "$MAX_BACKUPS"
      printf '%s\n' "$stripped" > "$BOOT_MP/cmdline.txt"
      sync || true
    else
      log_success "cmdline.txt already clean; no change"
    fi
  fi
else
  # If we boot via firmware (not U-Boot), ensure next boot root= points to the
  # just-installed target slot by updating /boot/cmdline.txt accordingly.
  log_check "Checking firmware boot configuration (non-U-Boot mode)..."
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
    current="$(cat "$BOOT_MP/cmdline.txt" 2>/dev/null || echo "")"
    stripped=$(printf '%s\n' "$current" | sed -E 's/(^| )root=[^ ]+//g' | tr -s ' ' | sed -E 's/^ +| +$//g')
    if [ -n "$stripped" ]; then
      newcmd="$stripped root=${TARGET_ROOT}"
    else
      newcmd="root=${TARGET_ROOT}"
    fi
    if [ "${current}" != "${newcmd}" ]; then
      log_update "Updating cmdline.txt root=${TARGET_ROOT} for next boot"
      bk="$BOOT_MP/cmdline.txt.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$BOOT_MP/cmdline.txt" "$bk" || true
      prune_backups "$BOOT_MP/cmdline.txt" "$MAX_BACKUPS"
      printf '%s\n' "$newcmd" > "$BOOT_MP/cmdline.txt"
      sync || true
    else
      log_success "cmdline.txt already points to ${TARGET_ROOT}; no change"
    fi
  fi
fi

log_success "Bundle post-install hook completed successfully"
exit 0
