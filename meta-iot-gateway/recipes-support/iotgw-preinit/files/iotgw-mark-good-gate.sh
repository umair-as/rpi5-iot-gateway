#!/bin/sh
# Mark-good gate for a degraded boot (/run/iotgw/degraded, set by iotgw-preinit).
#
# A degraded boot (no usable /data) normally still marks its slot good: both
# slots share /data, so falling back to the other slot cannot repair a storage
# fault, and spending the boot counters on it ends in U-Boot's halt. The one
# exception is a slot that has not yet had a healthy boot since it was
# installed: the new image itself may be what breaks /data, so it is not
# committed, and the boot counter falls back to the previous slot once it runs
# out. The previous slot is not on trial and is marked good even if degraded.
#
# The RAUC post-install hook records the installed slot's bootname in
# /uboot-env/iotgw-trial-slot. That partition is not /data, so the record is
# readable exactly when /data is not. The first healthy boot of that slot
# removes it.
#
#   check   ExecCondition of rauc-mark-good: exit 0 marks good, 1 skips.
#   commit  ExecStartPost of rauc-mark-good: the slot is good, drop its record.
# Any doubt (no record, unreadable record, unknown booted slot) marks good,
# which is how an image without this gate behaves. The post-install hook
# refuses an install whose record it cannot write durably, so "no record" means
# the slot already had its healthy boot or was installed before this gate.

STAMP=/uboot-env/iotgw-trial-slot
DEGRADED=/run/iotgw/degraded

booted=$(printf ' %s\n' "$(cat /proc/cmdline 2>/dev/null)" \
    | sed -n 's/.*[[:space:]]rauc\.slot=\([AB]\)\([[:space:]].*\)\{0,1\}$/\1/p')
trial=""
if [ -f "$STAMP" ] && [ ! -L "$STAMP" ]; then
    trial=$(head -c 16 "$STAMP" 2>/dev/null | tr -cd 'AB')
fi

case "${1:-}" in
    check)
        if [ -n "$booted" ] && [ "$trial" = "$booted" ] && [ -e "$DEGRADED" ]; then
            echo "slot $booted has not had a healthy boot since it was installed and this boot is degraded ($(cat "$DEGRADED" 2>/dev/null)): not marking it good" >&2
            exit 1
        fi
        exit 0
        ;;
    commit)
        if [ -n "$booted" ] && [ "$trial" = "$booted" ]; then
            if rm -f "$STAMP"; then
                echo "slot $booted: first healthy boot since install, trial record removed" >&2
            else
                echo "WARN: could not remove $STAMP; a later degraded boot of slot $booted will not be marked good" >&2
            fi
        fi
        exit 0
        ;;
    *)
        echo "usage: $0 check|commit" >&2
        exit 0
        ;;
esac
