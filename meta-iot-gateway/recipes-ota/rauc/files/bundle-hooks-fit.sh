#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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
die()         { log_error "$*"; exit 1; }
# Backward compatibility
log() { log_info "$*"; }

on_err() { log_error "failed at line ${1:-?}"; }
trap 'on_err $LINENO' ERR

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
VERBOSE="${IOTGW_VERBOSE:-0}"
VERBOSE_OVERLAYS="${IOTGW_VERBOSE_OVERLAYS:-0}"

for cmd in tar mount mountpoint install cmp sed awk sync grep sha256sum cp rm mkdir mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

case "${HOOK_TYPE:-}" in
  post-install)
    log_info "Hook type: post-install"
    ;;
  *)
    log_warn "Unknown or unset hook type '${HOOK_TYPE:-}' (expected post-install)"
    exit 0
    ;;
esac

# Reconcile selected /etc overlay upper files for the target slot being installed.
reconcile_overlay_upper() {
  local slot_mp="${RAUC_SLOT_MOUNT_POINT:-}"
  local state_dir="/data/iotgw/overlay-reconcile"
  local state_file="${state_dir}/state.tsv"
  local backup_root="${state_dir}/backups"
  local timestamp
  local state_tmp
  local backup_dir
  local manifest_main
  local manifest_dir
  local files_found=0
  local updated=0
  local preserved=0
  local -A seen_paths=()

  if [ -z "$slot_mp" ] || [ ! -d "$slot_mp" ]; then
    log_warn "RAUC_SLOT_MOUNT_POINT is missing; skipping overlay reconciliation"
    return 0
  fi

  manifest_main="${slot_mp}/usr/share/iotgw/overlay-reconcile/managed-paths.conf"
  manifest_dir="${slot_mp}/usr/share/iotgw/overlay-reconcile/managed-paths.d"
  if [ ! -f "$manifest_main" ] && [ ! -d "$manifest_dir" ]; then
    log_skip "No overlay reconcile manifest in target slot; skipping"
    return 0
  fi

  mkdir -p "$state_dir" "$backup_root"
  state_tmp=$(mktemp "${state_dir}/state.tsv.new.XXXXXX")
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
  backup_dir="${backup_root}/${timestamp}"

  state_get() {
    local p="$1"
    [ -f "$state_file" ] || return 0
    awk -F'\t' -v k="$p" '$1 == k { print $2; exit }' "$state_file"
  }

  process_manifest_file() {
    local mf="$1"
    local policy path rel desired upper desired_hash upper_hash prev_hash
    [ -f "$mf" ] || return 0
    files_found=1
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [ -n "$line" ] || continue
      case "$line" in
        \#*) continue ;;
      esac

      policy=$(printf '%s' "$line" | awk '{print $1}')
      path=$(printf '%s' "$line" | awk '{print $2}')
      if [ -z "$policy" ] || [ -z "$path" ]; then
        log_warn "Invalid manifest entry in ${mf}: '$line'"
        continue
      fi
      if [ -n "${seen_paths[$path]+x}" ]; then
        log_warn "Duplicate managed path '${path}' (source: ${mf}); skipping duplicate entry"
        continue
      fi
      seen_paths["$path"]=1
      case "$policy" in
        enforce|replace_if_unmodified|preserve) ;;
        *)
          log_warn "Unknown policy '${policy}' for ${path}; skipping"
          continue
          ;;
      esac
      case "$path" in
        /etc/*) ;;
        *)
          log_warn "Path '${path}' is not under /etc; skipping"
          continue
          ;;
      esac

      rel="${path#/etc/}"
      desired="${slot_mp}${path}"
      upper="/data/overlays/etc/upper/${rel}"
      if [ ! -f "$desired" ]; then
        log_warn "Desired target file missing in slot: ${desired}"
        continue
      fi
      desired_hash=$(sha256sum "$desired" | awk '{print $1}')
      prev_hash=$(state_get "$path")

      if [ -e "$upper" ] || [ -L "$upper" ]; then
        upper_hash=""
        if [ -f "$upper" ]; then
          upper_hash=$(sha256sum "$upper" | awk '{print $1}')
        fi

        case "$policy" in
          enforce)
            if [ "${upper_hash}" != "${desired_hash}" ]; then
              mkdir -p "${backup_dir}/$(dirname "$rel")"
              cp -a "$upper" "${backup_dir}/${rel}" 2>/dev/null || true
              rm -rf "$upper"
              updated=$((updated + 1))
              log_update "Removed stale overlay entry: ${path}"
            fi
            ;;
          replace_if_unmodified)
            if [ -n "${prev_hash}" ] && [ -n "${upper_hash}" ] && [ "${prev_hash}" = "${upper_hash}" ] && [ "${upper_hash}" != "${desired_hash}" ]; then
              mkdir -p "${backup_dir}/$(dirname "$rel")"
              cp -a "$upper" "${backup_dir}/${rel}" 2>/dev/null || true
              rm -rf "$upper"
              updated=$((updated + 1))
              log_update "Removed unmodified stale overlay entry: ${path}"
            else
              preserved=$((preserved + 1))
              log_info "Preserved local override: ${path}"
            fi
            ;;
          preserve)
            preserved=$((preserved + 1))
            ;;
        esac
      fi

      printf '%s\t%s\n' "$path" "$desired_hash" >> "$state_tmp"
    done < "$mf"
  }

  process_manifest_file "$manifest_main"
  if [ -d "$manifest_dir" ]; then
    for mf in "$manifest_dir"/*.conf; do
      [ -e "$mf" ] || continue
      process_manifest_file "$mf"
    done
  fi

  if [ "$files_found" -eq 0 ]; then
    rm -f "$state_tmp"
    log_skip "Overlay reconcile manifest list empty; skipping"
    return 0
  fi

  mv "$state_tmp" "$state_file"
  log_info "Overlay reconciliation complete: removed=${updated}, preserved=${preserved}"
  return 0
}

reconcile_overlay_upper

ARCHIVE="${BUNDLE_MNT}/bootfiles.tar.gz"
if [ ! -r "$ARCHIVE" ]; then
  log_skip "No bootfiles.tar.gz in bundle; skipping /boot update"
  log_success "Bundle post-install hook completed successfully"
  exit 0
fi

if [ ! -d "$BUNDLE_MNT" ]; then
  die "Bundle mount point missing: $BUNDLE_MNT"
fi

log_info "Summary: slot='${RAUC_SLOT_NAME:-unknown}', bundle='${ARCHIVE}', boot='${BOOT_DEV}'"

tmpdir=$(mktemp -d /tmp/bootfiles.XXXXXX)
cleanup() { rm -rf "$tmpdir" || true; }
trap cleanup EXIT INT TERM

log_install "Extracting bootfiles from bundle archive..."
tar -C "$tmpdir" -xzf "$ARCHIVE" || die "Failed to extract bootfiles"

# Validate module/kernel release alignment if possible
log_check "Validating kernel/module version alignment..."
mods_release=""
if [ -n "${RAUC_SLOT_MOUNT_POINT:-}" ]; then
  MODS_DIR="${RAUC_SLOT_MOUNT_POINT}/lib/modules"
  if [ -d "$MODS_DIR" ]; then
    for modpath in "$MODS_DIR"/*; do
      [ -d "$modpath" ] || continue
      mods_release=$(basename "$modpath")
      break
    done
  fi
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
  mount -t vfat "$BOOT_DEV" "$BOOT_MP" || die "Failed to mount $BOOT_DEV at $BOOT_MP"
else
  log_success "/boot is already mounted"
fi

# Try to ensure rw mount
if ! mount -o remount,rw "$BOOT_MP"; then
  log_warn "Failed to remount $BOOT_MP read-write"
fi

updated=0
bootfiles_changed=0
bootfiles_skipped=0
# Install file only when content differs
install_if_changed() {
  src="$1"
  dest="$2"
  mode="${3:-0644}"
  label="$4"
  quiet_skip="${5:-0}"

  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    if [ -n "$label" ] && [ "$quiet_skip" -eq 0 ] && [ "$VERBOSE" = "1" ]; then
      log_skip "$label unchanged"
    fi
    bootfiles_skipped=$((bootfiles_skipped + 1))
    return 1
  fi

  if [ -n "$label" ]; then
    if [ "$VERBOSE" = "1" ]; then
      log_install "Installing $label to /boot"
    else
      log_install "Updating $label"
    fi
  fi
  install -m "$mode" "$src" "$dest"
  bootfiles_changed=$((bootfiles_changed + 1))
  return 0
}

# FIT variant: stage fitImage first; keep Image/kernel_2712 for compatibility.
FILES=(boot.scr u-boot.bin splash.bmp fitImage Image kernel_2712.img bcm2712-rpi-5-b.dtb)
for f in "${FILES[@]}"; do
  if [ -f "$tmpdir/$f" ]; then
    label="$f"
    if [ "$VERBOSE" != "1" ]; then
      label="$f"
    fi
    if install_if_changed "$tmpdir/$f" "$BOOT_MP/$f" 0644 "$label"; then
      updated=1
    fi
  fi
done

# Include any additional Raspberry Pi 5 family DTBs shipped in bundle.
for dtb in "$tmpdir"/bcm2712-rpi-*.dtb; do
  [ -f "$dtb" ] || continue
  bn=$(basename "$dtb")
  if install_if_changed "$dtb" "$BOOT_MP/$bn" 0644 "$bn"; then
    updated=1
  fi
done

# Overlays directory (copy present files; keep logs concise unless verbose)
if [ -d "$tmpdir/overlays" ]; then
  mkdir -p "$BOOT_MP/overlays"
  # Build overlay allowlist from config.txt (dtoverlay=...)
  allowlist=""
  if [ -r "$BOOT_MP/config.txt" ]; then
    allowlist=$(grep -E '^[[:space:]]*dtoverlay=' "$BOOT_MP/config.txt" \
      | sed -E 's/^[[:space:]]*dtoverlay=([^,[:space:]]+).*/\1/' \
      | tr '\n' ' ' || true)
  fi
  # Always allow overlay_map metadata if present
  allowlist="${allowlist} overlay_map overlay_map_pi5"

  overlays_copied=0
  overlays_total=0
  for f in "$tmpdir"/overlays/*; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    base="${bn%.dtbo}"
    base="${base%.dtb}"
    if [ -n "$allowlist" ]; then
      case " $allowlist " in
        *" ${base} "*) ;;
        *) continue ;;
      esac
    fi
    overlays_total=$((overlays_total + 1))
    label=""
    if [ "$VERBOSE_OVERLAYS" = "1" ]; then
      label="overlays/$bn"
    fi
    if install_if_changed "$f" "$BOOT_MP/overlays/$bn" 0644 "$label" 1; then
      overlays_copied=$((overlays_copied + 1))
      updated=1
    fi
  done
  if [ "${overlays_total}" -gt 0 ]; then
    if [ "${overlays_copied}" -gt 0 ]; then
      log_install "Installed ${overlays_copied}/${overlays_total} overlay file(s) to /boot/overlays"
    else
      log_skip "Overlays unchanged (${overlays_total} file(s))"
    fi
  fi
fi

# Ensure kernel_2712.img exists for Pi5 firmware even if bundle only shipped Image
if [ ! -f "$tmpdir/kernel_2712.img" ] && [ -f "$tmpdir/Image" ]; then
  if install_if_changed "$tmpdir/Image" "$BOOT_MP/kernel_2712.img" 0644 "kernel_2712.img (from Image)"; then
    updated=1
  fi
fi

if [ "$updated" -eq 1 ]; then
  sync || true
  log_success "Boot files updated: ${bootfiles_changed} changed, ${bootfiles_skipped} unchanged"
else
  log_skip "Boot files already up-to-date"
fi

# Persist bundle metadata to U-Boot environment when available
if command -v fw_setenv >/dev/null 2>&1; then
  now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
  if [ -n "${RAUC_SLOT_NAME:-}" ]; then
    fw_setenv iotgw_last_slot "${RAUC_SLOT_NAME}" || log_warn "failed to set iotgw_last_slot"
  fi
  if [ -n "$now_utc" ]; then
    fw_setenv iotgw_last_update "$now_utc" || log_warn "failed to set iotgw_last_update"
  fi
  log_info "Updated U-Boot env (iotgw_last_slot/iotgw_last_update)"
else
  log_warn "fw_setenv not available; skipping U-Boot env update"
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
