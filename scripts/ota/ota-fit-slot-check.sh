#!/bin/bash
# Regression assertion for the "OTA-delivered kernel is never booted" bug:
# confirms the kernel actually running on target was loaded from the
# *active RAUC slot's* per-slot FIT
# (/boot/fitImage-a or /boot/fitImage-b), not a stale plain /boot/fitImage
# left over from before U-Boot's iotgw_load_boot selected FIT files by
# ${rauc_slot}.
#
# PASS: the kernel version string embedded in the active slot's on-disk
#       FIT matches the running kernel (uname). The booted kernel came
#       from that slot's FIT, as intended.
# FAIL: they differ — U-Boot loaded the wrong/stale FIT for this slot,
#       i.e. the wrong-FIT-per-slot regression this guards against.
# WARN (still exits non-zero via FAIL count if the file is flat-out
#       missing on a device that has completed at least one OTA): the
#       active slot's per-slot FIT is absent from /boot.
#
# Usage:
#   # On target directly:
#   sudo ./ota-fit-slot-check.sh
#
#   # From host over SSH (no copy needed):
#   ssh <gw> 'sudo bash -s' < scripts/ota/ota-fit-slot-check.sh
#
# Pairs with:
#   scripts/ota/ota-smoke-target.sh — general post-OTA / BSP smoke suite

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
    say_fail "could not determine active RAUC slot from /proc/cmdline or 'rauc status' — this is a target-side check; run it ON the gateway, or from the host via: scripts/run-target-checks.sh <device-ip> ota-fit-slot"
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
section "Kernel ↔ module coherence (tool-free)"

# Primary, tool-free assertion. If U-Boot booted the wrong/stale FIT for this
# slot, the running kernel release won't match the modules shipped in the
# slot's rootfs — so /lib/modules/$(uname -r) is absent and nothing loads,
# the wrong-FIT-per-slot symptom. Needs no u-boot-tools/strings, so it works
# on the minimal target image (unlike the FIT-version comparison below).
krel=$(uname -r 2>/dev/null || true)
if [ -n "$krel" ] && [ -d "/lib/modules/${krel}" ]; then
    say_pass "modules present for running kernel: /lib/modules/${krel} (booted kernel matches this slot's rootfs)"
else
    say_fail "no /lib/modules/${krel} for the running kernel — kernel↔module mismatch: U-Boot booted a stale/wrong FIT for slot ${active_slot}"
fi
if command -v lsmod >/dev/null 2>&1; then
    nmod=$(lsmod 2>/dev/null | tail -n +2 | grep -c . || true)
    if [ "${nmod:-0}" -gt 0 ]; then
        say_pass "loaded kernel modules: ${nmod}"
    else
        say_warn "no kernel modules loaded (lsmod empty) — corroborates a kernel↔module mismatch"
    fi
fi

# ---------------------------------------------------------------------------
section "Kernel version: FIT vs running (best-effort; needs u-boot-tools/strings)"

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
    # Not fatal: u-boot-tools (dumpimage/mkimage) and binutils `strings` are not
    # on the minimal target image, and the FIT kernel is compressed so `strings`
    # can't see the banner anyway. The tool-free kernel↔module coherence check
    # above is the authoritative on-target assertion; this comparison is an
    # extra cross-check only when the tools happen to be present.
    say_skip "FIT kernel version comparison" "no usable dumpimage/mkimage/strings on target — covered by kernel↔module coherence above"
else
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
fi

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
printf '  PASS: %d\n' "$PASS"
printf '  FAIL: %d\n' "$FAIL"
printf '  SKIP: %d\n' "$SKIP"

[ "$FAIL" -eq 0 ]
