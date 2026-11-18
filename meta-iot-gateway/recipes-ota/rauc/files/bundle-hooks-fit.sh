#!/usr/bin/env bash
# RAUC bundle hook for the raw dm-verity root slots (pre-install, post-install).
#
# An OTA install writes only what belongs to the target slot: its signed FIT
# (/boot/fitImage-a or -b), the trial-slot record and the U-Boot env metadata.
# It never writes the shared boot files (u-boot.bin, the board DTB that holds
# the FIT trust anchor, config.txt): /boot is single-copy, so a bad write there
# would take both slots down and no slot switch could roll it back. Those
# change only through iotgw-rpi-bootfiles-update, run by an operator, which
# refuses a DTB that does not trust both installed slot FITs.
set -euo pipefail
IFS=$'\n\t'

# Logging
# Default level is INFO. Set IOTGW_HOOK_LOG_LEVEL=DEBUG for verbose traces.
HOOK_LOG_LEVEL="${IOTGW_HOOK_LOG_LEVEL:-INFO}"
case "${HOOK_LOG_LEVEL}" in
  error|ERROR) HOOK_LOG_LEVEL="ERROR" ;;
  warn|WARN|warning|WARNING) HOOK_LOG_LEVEL="WARN" ;;
  debug|DEBUG) HOOK_LOG_LEVEL="DEBUG" ;;
  *) HOOK_LOG_LEVEL="INFO" ;;
esac

_log_level_num() {
  case "$1" in
    ERROR) echo 0 ;;
    WARN) echo 1 ;;
    INFO) echo 2 ;;
    DEBUG) echo 3 ;;
    *) echo 2 ;;
  esac
}

_log() {
  local level="$1"
  shift
  local wanted current
  wanted=$(_log_level_num "$level")
  current=$(_log_level_num "$HOOK_LOG_LEVEL")
  [ "$wanted" -le "$current" ] || return 0
  printf '[bundle-hook][%s] %s\n' "$level" "$*" >&2
}

log_error()   { _log ERROR "$*"; }
log_warn()    { _log WARN "$*"; }
log_info()    { _log INFO "$*"; }
log_success() { _log INFO "$*"; }
log_update()  { _log INFO "$*"; }
log_clean()   { _log DEBUG "$*"; }
log_install() { _log DEBUG "$*"; }
log_check()   { _log DEBUG "$*"; }
log_skip()    { _log DEBUG "$*"; }
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

for cmd in tar mount mountpoint umount install cmp sed awk sync grep cp rm mkdir mktemp mv; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# A boot without a usable /data (iotgw-preinit marker) runs in a restricted
# recovery mode and must not take an update: bundle staging and RAUC's slot
# status live on /data. Checked here, the one step every install path (CLI,
# D-Bus, streaming, ota-updater) goes through.
DEGRADED_MARKER="/run/iotgw/degraded"
refuse_if_degraded() {
  if [ -e "$DEGRADED_MARKER" ]; then
    die "Refusing to install: this boot is degraded ($(cat "$DEGRADED_MARKER" 2>/dev/null || echo unknown)); repair /data and reboot first"
  fi
}

# The installed slot is on trial until its first healthy boot: a degraded boot
# of it is not marked good (iotgw-mark-good-gate). The record sits on the
# U-Boot environment partition, which stays readable when /data is not.
# Without a durable record the install fails: the gate cannot tell a new slot
# from a committed one, and a slot switch needs /uboot-env writable anyway.
TRIAL_RECORD="/uboot-env/iotgw-trial-slot"
record_trial_slot() {
  local bootname="${RAUC_SLOT_BOOTNAME:-}"
  if [ -z "$bootname" ]; then
    case "${RAUC_SLOT_NAME:-}" in
      rootfs.0) bootname="A" ;;
      rootfs.1) bootname="B" ;;
    esac
  fi
  case "$bootname" in
    A|B) ;;
    *) log_error "Unknown bootname '${bootname}' for ${RAUC_SLOT_NAME:-?}"; return 1 ;;
  esac
  if ! mountpoint -q /uboot-env; then
    log_error "/uboot-env is not mounted"
    return 1
  fi
  if printf '%s\n' "$bootname" > "${TRIAL_RECORD}.new" && sync && mv -f "${TRIAL_RECORD}.new" "$TRIAL_RECORD" && sync; then
    log_info "Slot ${bootname} on trial until its first healthy boot"
  else
    rm -f "${TRIAL_RECORD}.new" 2>/dev/null || true
    log_error "Could not write ${TRIAL_RECORD}"
    return 1
  fi
}

ARCHIVE="${BUNDLE_MNT}/bootfiles-fit.tar.gz"

# Each root slot boots its own signed FIT: /boot/fitImage-a or /boot/fitImage-b.
# The bundle carries both (<image>.fitImage-a / <image>.fitImage-b); their
# device trees hold the dm-verity table for exactly this rootfs.
case "${RAUC_SLOT_NAME:-}" in
  rootfs.0) FIT_DEST_NAME="fitImage-a" ;;
  rootfs.1) FIT_DEST_NAME="fitImage-b" ;;
  *) FIT_DEST_NAME="" ;;
esac

find_slot_fit() {
  local candidate found=""
  [ -n "$FIT_DEST_NAME" ] || return 0
  for candidate in "$BUNDLE_MNT"/*."$FIT_DEST_NAME"; do
    [ -f "$candidate" ] && found="$candidate"
  done
  printf '%s' "$found"
}

# Root slots are raw dm-verity slots. A filesystem slot means a device still on
# the pre-verity layout, which can only move to verity by reflashing. The root
# hash lives only in the per-slot FIT, so a bundle that cannot deliver it would
# leave the slot unbootable. Checked in pre-install, before RAUC writes the
# slot, and again in post-install before anything in the shared /boot is
# touched.
require_verity_slot() {
  [ -n "$FIT_DEST_NAME" ] || die "Unsupported RAUC slot '${RAUC_SLOT_NAME:-}'"
  [ "${RAUC_SLOT_TYPE:-}" = "raw" ] \
    || die "Root slot ${RAUC_SLOT_NAME} is type '${RAUC_SLOT_TYPE:-unknown}', not a raw dm-verity slot; this device predates runtime dm-verity and must be reflashed"
  [ -r "$ARCHIVE" ] \
    || die "Bundle has no bootfiles-fit.tar.gz; it cannot update dm-verity slot ${RAUC_SLOT_NAME}"
  [ -n "$(find_slot_fit)" ] \
    || die "Bundle carries no *.${FIT_DEST_NAME} for dm-verity slot ${RAUC_SLOT_NAME}"
}

# RAUC does not mount a raw slot for post-install, but the module check reads
# the new slot. Mount the (ext4 + appended hash tree) slot read-only; noload
# skips journal replay, which would write to the data blocks and invalidate the
# root hash.
SLOT_MNT=""
release_slot_mount() {
  [ -n "$SLOT_MNT" ] || return 0
  umount "$SLOT_MNT" || log_warn "failed to unmount $SLOT_MNT"
  rmdir "$SLOT_MNT" 2>/dev/null || true
  SLOT_MNT=""
}
mount_raw_slot() {
  [ -n "${RAUC_SLOT_DEVICE:-}" ] || die "RAUC_SLOT_DEVICE not set for raw slot ${RAUC_SLOT_NAME:-unknown}"
  SLOT_MNT=$(mktemp -d /run/iotgw-slot.XXXXXX)
  trap release_slot_mount EXIT
  mount -t ext4 -o ro,noload "$RAUC_SLOT_DEVICE" "$SLOT_MNT" \
    || die "Failed to mount raw slot $RAUC_SLOT_DEVICE read-only"
  export RAUC_SLOT_MOUNT_POINT="$SLOT_MNT"
}

# Release of the first kernel module tree in the new slot, or empty.
slot_modules_release() {
  local modpath
  [ -n "${RAUC_SLOT_MOUNT_POINT:-}" ] || return 0
  for modpath in "${RAUC_SLOT_MOUNT_POINT}/lib/modules"/*; do
    [ -d "$modpath" ] || continue
    basename "$modpath"
    return 0
  done
}

case "${HOOK_TYPE:-}" in
  pre-install)
    log_info "Hook type: pre-install"
    refuse_if_degraded
    require_verity_slot
    log_success "Bundle pre-install hook completed successfully"
    exit 0
    ;;
  post-install)
    log_info "Hook type: post-install"
    require_verity_slot
    mount_raw_slot
    ;;
  *)
    log_warn "Unknown or unset hook type '${HOOK_TYPE:-}' (expected pre-install or post-install)"
    exit 0
    ;;
esac

if [ ! -d "$BUNDLE_MNT" ]; then
  die "Bundle mount point missing: $BUNDLE_MNT"
fi

log_info "Summary: slot='${RAUC_SLOT_NAME:-unknown}', bundle='${ARCHIVE}', boot='${BOOT_DEV}'"

tmpdir=$(mktemp -d /tmp/bootfiles.XXXXXX)
boot_mounted_by_hook=0
boot_was_readonly=0
cleanup() {
  if [ "$boot_mounted_by_hook" -eq 1 ]; then
    if mountpoint -q "$BOOT_MP"; then
      umount "$BOOT_MP" || log_warn "failed to unmount $BOOT_MP during cleanup"
    fi
  elif [ "$boot_was_readonly" -eq 1 ]; then
    # A plain `remount,ro` flips the mount flags but never releases the
    # mount, so the FAT dirty bit set during the r/w write phase is never
    # cleared — every subsequent boot then logs a spurious "Volume was not
    # properly unmounted" warning. Only a real umount clears the bit. Fall
    # back to remount,ro if something else still holds /boot open.
    sync
    if umount "$BOOT_MP" 2>/dev/null; then
      mount -t vfat -o ro "$BOOT_DEV" "$BOOT_MP" \
        || log_warn "failed to remount $BOOT_MP ro after sync cycle"
    else
      mount -o remount,ro "$BOOT_MP" \
        || log_warn "failed to remount $BOOT_MP read-only during cleanup"
    fi
  fi
  rm -rf "$tmpdir" || true
  release_slot_mount
}
trap cleanup EXIT INT TERM

log_install "Extracting bootfiles from bundle archive..."
tar -C "$tmpdir" -xzf "$ARCHIVE" || die "Failed to extract bootfiles"

# Validate module/kernel release alignment if possible
log_check "Validating kernel/module version alignment..."
mods_release=$(slot_modules_release)
expected_release=""
if [ -f "$tmpdir/kernel.release" ]; then
  expected_release="$(cat "$tmpdir/kernel.release" 2>/dev/null || true)"
fi
[ -n "$expected_release" ] || die "Bundle bootfiles archive carries no kernel.release; cannot pair the kernel with the slot's modules"
if [ -n "$mods_release" ] && [ "$expected_release" != "$mods_release" ]; then
  log_error "Kernel/module mismatch: expected '$expected_release' but rootfs has modules for '$mods_release'"
  exit 1
fi
if [ -n "$mods_release" ]; then
  log_success "Kernel release validation passed: $expected_release"
fi

# Ensure /boot is mounted
log_check "Checking /boot mount status..."
if ! mountpoint -q "$BOOT_MP"; then
  log_install "Mounting $BOOT_DEV at $BOOT_MP..."
  mkdir -p "$BOOT_MP"
  mount -t vfat "$BOOT_DEV" "$BOOT_MP" || die "Failed to mount $BOOT_DEV at $BOOT_MP"
  boot_mounted_by_hook=1
else
  mount_opts="$(awk -v mp="$BOOT_MP" '$2==mp {print $4; exit}' /proc/mounts 2>/dev/null || true)"
  case ",${mount_opts}," in
    *,ro,*) boot_was_readonly=1 ;;
  esac
  log_success "/boot is already mounted"
fi

# Try to ensure rw mount
if ! mount -o remount,rw "$BOOT_MP"; then
  log_warn "Failed to remount $BOOT_MP read-write"
fi

log_info "FIT destination: ${FIT_DEST_NAME} (slot=${RAUC_SLOT_NAME:-unknown})"

# Install the slot's verity FIT (fitImage-a or fitImage-b). The generic
# fitImage in the archive has no verity table and is never installed. Write a
# temporary file and rename it, so a power cut leaves the old FIT or the new
# one, never a torn file.
slot_fit=$(find_slot_fit)
fit_target="$BOOT_MP/$FIT_DEST_NAME"
if [ -f "$fit_target" ] && cmp -s "$slot_fit" "$fit_target"; then
  log_skip "$FIT_DEST_NAME unchanged"
else
  log_install "Updating $FIT_DEST_NAME"
  install -m 0644 "$slot_fit" "$BOOT_MP/.$FIT_DEST_NAME.new"
  sync
  mv -f "$BOOT_MP/.$FIT_DEST_NAME.new" "$fit_target"
  sync
  log_success "$FIT_DEST_NAME installed"
fi
record_trial_slot || die "Trial record not written; refusing the install (slot left inactive)"

# Persist bundle metadata to U-Boot environment when available
if command -v fw_setenv >/dev/null 2>&1; then
  now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)
  if [ -n "${RAUC_SLOT_NAME:-}" ]; then
    fw_setenv iotgw_last_slot "${RAUC_SLOT_NAME}" || log_warn "failed to set iotgw_last_slot"
  fi
  if [ -n "$now_utc" ]; then
    fw_setenv iotgw_last_update "$now_utc" || log_warn "failed to set iotgw_last_update"
  fi
  # The FIT config is selected by the FIT's own signed `default` property
  # (U-Boot boots with no explicit #conf); iotgw_fit_conf is an operator
  # override only (none is currently defined). DELETE any value a
  # previous build or hook persisted — both slots load the same FIT, so a
  # stale pinned name fails bootm on every slot and exhausts all boot
  # counters. Clearing here self-heals devices that installed a bundle
  # from a build with a different config name.
  # Dev-posture caveat: on dev builds the whole SAVED env is imported (prod's
  # ENV_WRITEABLE_LIST keeps boot scripts read-only), so a device flashed before
  # a boot-script change keeps its old scripts. The boot-critical self-heal below
  # corrects that automatically from the bundle's uboot-env.txt; clearing
  # iotgw_fit_conf* here remains, since those keys are intentionally absent from
  # the default env (operator override only).
  fw_setenv iotgw_fit_conf || log_warn "failed to clear iotgw_fit_conf"
  fw_setenv iotgw_fit_conf_default || log_warn "failed to clear iotgw_fit_conf_default"

  # Self-heal boot-critical U-Boot env from the bundle's canonical uboot-env.txt
  # (built from u-boot.bin's own initial-env dump). Corrects a stale saved env —
  # e.g. an older iotgw_load_boot that loads plain fitImage instead of the
  # per-slot fitImage-<a|b>, which otherwise strands an OTA'd kernel on dev
  # builds. Only vars present in the (build-time pre-filtered) file are touched,
  # so runtime state (BOOT_ORDER, BOOT_*_LEFT, bootcount) is never modified. Each
  # var is written only when it differs → a no-op on an already-current device.
  healed=0
  env_file="$tmpdir/uboot-env.txt"
  if [ -r "$env_file" ]; then
    while IFS= read -r kv || [ -n "$kv" ]; do
      case "$kv" in ''|'#'*) continue ;; esac
      key=${kv%%=*}
      val=${kv#*=}
      if [ "$key" = "$kv" ]; then continue; fi   # no '=' → malformed, skip
      cur=$(fw_printenv -n "$key" 2>/dev/null || true)
      if [ "$cur" != "$val" ]; then
        if fw_setenv "$key" "$val"; then
          log_info "Self-healed boot-critical env var: $key"
          healed=$((healed + 1))
        else
          log_warn "failed to self-heal env var: $key"
        fi
      fi
    done < "$env_file"
  else
    log_skip "No uboot-env.txt in bundle; skipping boot-critical env self-heal"
  fi

  if [ "$healed" -gt 0 ]; then
    log_info "Updated U-Boot env (metadata; cleared iotgw_fit_conf*; self-healed ${healed} boot-critical var(s))"
  else
    log_info "Updated U-Boot env (metadata; cleared iotgw_fit_conf*; boot-critical env already current)"
  fi
else
  log_warn "fw_setenv not available; skipping U-Boot env update"
fi

log_success "Bundle post-install hook completed successfully"
exit 0
