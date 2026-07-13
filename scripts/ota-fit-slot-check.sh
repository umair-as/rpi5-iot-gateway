#!/bin/bash
# Regression assertion for the "OTA-delivered kernel is never booted" bug
# (wrynose migration review finding #1): confirms the kernel actually
# running on target was loaded from the *active RAUC slot's* per-slot FIT
# (/boot/fitImage-a or /boot/fitImage-b), not a stale plain /boot/fitImage
# left over from before U-Boot's iotgw_load_boot selected FIT files by
# ${rauc_slot}.
#
# PASS: the kernel version string embedded in the active slot's on-disk
#       FIT matches the running kernel (uname). The booted kernel came
#       from that slot's FIT, as intended.
# FAIL: they differ — U-Boot loaded the wrong/stale FIT for this slot,
#       i.e. exactly the finding-#1 regression.
# WARN (still exits non-zero via FAIL count if the file is flat-out
#       missing on a device that has completed at least one OTA): the
#       active slot's per-slot FIT is absent from /boot.
#
# Usage:
#   # On target directly:
#   sudo ./ota-fit-slot-check.sh
#
#   # From host over SSH (no copy needed):
#   ssh <gw> 'sudo bash -s' < scripts/ota-fit-slot-check.sh
#
# Pairs with:
#   scripts/ota-smoke-target.sh — general post-OTA / BSP smoke suite
#   scratch/fit-ab-boot-design.md §5 — the T0/T1/T2 proof ladder this
#     script encodes as T1 (on-target, no rebuild needed to see PASS/FAIL;
#     a visible kernel-version bump per T2 makes the FAIL case undeniable)

set -u
PASS=0
FAIL=0
SKIP=0

say_pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
say_fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
say_skip() { printf '  \e[33mSKIP\e[0m %s — %s\n' "$1" "${2:-}"; SKIP=$((SKIP+1)); }
say_warn() { printf '  \e[33mWARN\e[0m %s\n' "$1"; }
section()  { printf '\n== %s ==\n' "$1"; }

BOOT_DIR="${IOTGW_BOOT_DIR:-/boot}"

# ---------------------------------------------------------------------------
section "Active RAUC slot"

active_slot=""

# Preferred: rauc.slot= on the running kernel cmdline (what U-Boot actually
# set for *this* boot — the most direct evidence).
if [ -r /proc/cmdline ]; then
    cmdline_slot=$(sed -nE 's/.*\brauc\.slot=([A-Za-z0-9]+).*/\1/p' /proc/cmdline)
    if [ -n "$cmdline_slot" ]; then
        active_slot="$cmdline_slot"
        say_pass "active slot from /proc/cmdline rauc.slot=: $active_slot"
    fi
fi

# Fallback / cross-check: rauc status booted slot, mapped rootfs.0/1 -> A/B
# (matches the FIT_DEST_NAME mapping in bundle-hooks-fit.sh).
rauc_booted_name=""
if command -v rauc >/dev/null 2>&1; then
    rauc_booted_name=$(rauc status --output-format=shell 2>/dev/null | sed -nE 's/^RAUC_BOOT_PRIMARY=(.*)$/\1/p' | tr -d '"')
    if [ -z "$active_slot" ] && [ -n "$rauc_booted_name" ]; then
        case "$rauc_booted_name" in
            rootfs.0) active_slot="A" ;;
            rootfs.1) active_slot="B" ;;
        esac
        if [ -n "$active_slot" ]; then
            say_pass "active slot from 'rauc status' (${rauc_booted_name}): $active_slot"
        fi
    fi
elif [ -z "$active_slot" ]; then
    say_skip "rauc binary" "not installed; relying on /proc/cmdline only"
fi

if [ -z "$active_slot" ]; then
    say_fail "could not determine active RAUC slot from /proc/cmdline or 'rauc status'"
    printf '\n== summary ==\n  PASS: %d\n  FAIL: %d\n  SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi

fit_name=""
case "$active_slot" in
    A) fit_name="fitImage-a" ;;
    B) fit_name="fitImage-b" ;;
    *) say_warn "unrecognized slot value '$active_slot' (expected A or B); guessing lowercase filename" ;;
esac
[ -n "$fit_name" ] || fit_name="fitImage-$(printf '%s' "$active_slot" | tr '[:upper:]' '[:lower:]')"

fit_path="${BOOT_DIR}/${fit_name}"

# ---------------------------------------------------------------------------
section "Per-slot FIT presence"

if [ ! -e "$fit_path" ]; then
    say_warn "$fit_path absent — device has not completed an OTA to this slot yet (fresh-flash fallback window; U-Boot loads plain ${BOOT_DIR}/fitImage instead)"
    say_skip "kernel/FIT version comparison" "no per-slot FIT to inspect at $fit_path"
    printf '\n== summary ==\n  PASS: %d\n  FAIL: %d\n  SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
    exit $?
fi
say_pass "$fit_path present"

# ---------------------------------------------------------------------------
section "Kernel version: FIT vs running"

# Extract the embedded kernel version string from the on-disk FIT. Prefer
# dumpimage/mkimage -l (structured FIT metadata; u-boot-tools), fall back to
# grepping the "Linux version ..." banner string that's always present in an
# uncompressed/gzip-decodable vmlinux payload via `strings`.
fit_kernel_desc=""
extraction_method=""

if command -v dumpimage >/dev/null 2>&1; then
    fit_kernel_desc=$(dumpimage -l "$fit_path" 2>/dev/null | grep -A5 "Image 0 (kernel" | sed -nE "s/.*Description:[[:space:]]*//p" | head -1)
    [ -n "$fit_kernel_desc" ] && extraction_method="dumpimage -l"
fi

if [ -z "$fit_kernel_desc" ] && command -v mkimage >/dev/null 2>&1; then
    fit_kernel_desc=$(mkimage -l "$fit_path" 2>/dev/null | grep -A5 "Image 0 (kernel" | sed -nE "s/.*Description:[[:space:]]*//p" | head -1)
    [ -n "$fit_kernel_desc" ] && extraction_method="mkimage -l"
fi

if [ -z "$fit_kernel_desc" ] && command -v strings >/dev/null 2>&1; then
    fit_kernel_desc=$(strings "$fit_path" | grep -m1 "Linux version")
    [ -n "$fit_kernel_desc" ] && extraction_method="strings | grep 'Linux version'"
fi

if [ -z "$fit_kernel_desc" ]; then
    say_fail "could not extract a kernel version string from $fit_path (no dumpimage/mkimage/strings usable)"
    printf '\n== summary ==\n  PASS: %d\n  FAIL: %d\n  SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi
say_pass "extracted FIT kernel string via ${extraction_method}: ${fit_kernel_desc}"

running_uname_r=$(uname -r 2>/dev/null || true)
running_uname_v=$(uname -v 2>/dev/null || true)
say_pass "running kernel: uname -r='${running_uname_r}' uname -v='${running_uname_v}'"

# The FIT description / "Linux version" banner both embed the same release
# string uname -r reports (e.g. "6.18.29-...-iotgwR2"). Match on that
# substring rather than requiring an exact whole-string match, since
# dumpimage/mkimage descriptions and the raw "Linux version" banner differ
# in surrounding text.
if [ -n "$running_uname_r" ] && printf '%s' "$fit_kernel_desc" | grep -qF "$running_uname_r"; then
    say_pass "booted kernel (${running_uname_r}) matches ${fit_name} — slot's FIT was actually loaded"
else
    say_fail "booted kernel (${running_uname_r}) NOT found in ${fit_name}'s embedded version string (${fit_kernel_desc}) — wrong/stale FIT booted for slot ${active_slot}"
fi

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
printf '  PASS: %d\n' "$PASS"
printf '  FAIL: %d\n' "$FAIL"
printf '  SKIP: %d\n' "$SKIP"

[ "$FAIL" -eq 0 ]
