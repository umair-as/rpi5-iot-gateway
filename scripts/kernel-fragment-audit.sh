#!/bin/bash
# Audit iotgw kernel config fragments against the compiled .config.
#
# For every CONFIG directive in the applied fragments, verifies the final
# .config honoured it, and classifies misses:
#   MISMATCH — different value (y vs m, wrong int, or forced-on despite
#              "is not set")
#   UNMET    — requested =y/=m but final config says "not set"
#              (dependencies not satisfied)
#   ABSENT   — symbol exists in the kernel Kconfig tree but never appears
#              in .config (dependency gate never exposed it)
#   REMOVED  — symbol no longer exists in this kernel's Kconfig tree
#              (deprecated/renamed upstream — fragment line is dead)
#
# Run after any kernel version bump or fragment edit. Requires a completed
# kernel build (reads work-shared artifacts; survives rm_work).
#
# Usage:
#   ./scripts/kernel-fragment-audit.sh [fragment.cfg ...]
#   (no args: audits the fragment set applied by the current dev build)
#
# Exits non-zero if any MISMATCH/UNMET/REMOVED is found.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FRAGDIR=$REPO/meta-iot-gateway/recipes-kernel/linux/files/fragments
DOTCONFIG=${DOTCONFIG:-$REPO/build/tmp/work-shared/raspberrypi5/kernel-build-artifacts/.config}
KSRC=${KSRC:-$REPO/build/tmp/work-shared/raspberrypi5/kernel-source}

[ -r "$DOTCONFIG" ] || { echo "ERROR: no .config at $DOTCONFIG (build the kernel first)"; exit 2; }
[ -d "$KSRC" ] || { echo "ERROR: no kernel source at $KSRC"; exit 2; }

# Default = fragments applied by the current dev build:
# base set + default-on gates (panic-on-oops, rtc, vcio) + local.yml
# IOTGW_KERNEL_FEATURES (igw_compute_media igw_containers
# igw_networking_iot igw_security_prod igw_ima) + recipe thermal append.
# Keep in sync with classes/iotgw-kernel-fragments.bbclass; or pass an
# explicit list, e.g.:
#   kas shell -c 'bitbake -e linux-iotgw-mainline-fit' kas/local.yml \
#     | sed -n 's/^IOTGW_KERNEL_FRAGMENTS="//p'
DEFAULT_SET="branding.cfg trim.cfg storage-filesystems.cfg ikconfig.cfg
audit.cfg panic-recovery.cfg panic-on-oops.cfg rtc-rpi.cfg vcio-rpi.cfg
compute-media.cfg containers-cgroups.cfg networking-iot.cfg
security-prod.cfg ima.cfg thermal-rpi5.cfg
pstore-persist.cfg tpm-slb9672.cfg"

FRAGS="${*:-$DEFAULT_SET}"

total=0; ok=0; mism=0; unmet=0; removed=0

symbol_exists() {
    local sym="${1#CONFIG_}"
    grep -rqE "^(menu)?config[[:space:]]+${sym}\$" "$KSRC" \
        --include=Kconfig --include="Kconfig.*" 2>/dev/null
}

for f in $FRAGS; do
    frag="$FRAGDIR/${f##*/}"
    [ -f "$frag" ] || { echo "!! fragment not found: $f"; mism=$((mism+1)); continue; }
    hdr=0
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*)                  sym=${line%%=*}; want=${line#*=} ;;
            "# CONFIG_"*" is not set")   sym=${line#\# }; sym=${sym%% *}; want="n" ;;
            *) continue ;;
        esac
        total=$((total+1))
        got=$(grep -E "^${sym}=" "$DOTCONFIG" | head -1)
        if [ "$want" = "n" ]; then
            if [ -z "$got" ]; then ok=$((ok+1)); continue; fi
            [ $hdr -eq 0 ] && { echo; echo "== ${f##*/} =="; hdr=1; }
            echo "  MISMATCH  $sym: fragment says 'not set', .config has '${got#*=}'"
            mism=$((mism+1))
        else
            if [ "$got" = "$sym=$want" ]; then ok=$((ok+1)); continue; fi
            [ $hdr -eq 0 ] && { echo; echo "== ${f##*/} =="; hdr=1; }
            if [ -n "$got" ]; then
                echo "  MISMATCH  $sym: want '$want', .config has '${got#*=}'"
                mism=$((mism+1))
            elif grep -qE "^# ${sym} is not set\$" "$DOTCONFIG"; then
                echo "  UNMET     $sym=$want requested but 'is not set' in .config"
                unmet=$((unmet+1))
            elif symbol_exists "$sym"; then
                echo "  ABSENT    $sym=$want requested; symbol in Kconfig tree but absent from .config"
                unmet=$((unmet+1))
            else
                echo "  REMOVED   $sym=$want requested; symbol NOT in this kernel's Kconfig (deprecated/renamed)"
                removed=$((removed+1))
            fi
        fi
    done < "$frag"
done

echo
echo "Summary: total=$total ok=$ok mismatch=$mism unmet/absent=$unmet removed=$removed"
[ $((mism + unmet + removed)) -eq 0 ]
