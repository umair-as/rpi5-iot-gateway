#!/bin/sh
# Relabel /data when the SELinux policy or file contexts differ from the ones
# it was last labelled with. The stamp is a hash of everything restorecon reads,
# so a new policy (OTA to a slot with different contexts) or a first boot
# relabels once, and every other boot is a no-op.
set -eu

DATA=/data
STAMP="${DATA}/.iotgw-selinux-labels"
CONFIG=/etc/selinux/config

log() { echo "iotgw-selinux-relabel: $*"; }

policy_type=$(sed -n 's/^SELINUXTYPE=[[:space:]]*//p' "$CONFIG")
[ -n "$policy_type" ] || { log "no SELINUXTYPE in $CONFIG"; exit 1; }
fc="/etc/selinux/${policy_type}/contexts/files"

# Missing optional files (file_contexts.local, .subs) hash as absent.
want=$(for f in "$CONFIG" "$fc/file_contexts" "$fc/file_contexts.homedirs" \
                "$fc/file_contexts.local" "$fc/file_contexts.subs" \
                "$fc/file_contexts.subs_dist" /etc/selinux/"${policy_type}"/policy/policy.*; do
           if [ -f "$f" ]; then printf '%s ' "$f"; sha256sum < "$f"; else printf '%s absent\n' "$f"; fi
       done | sha256sum | cut -d' ' -f1)
have=$(cat "$STAMP" 2>/dev/null || true)

if [ "$want" = "$have" ]; then
    log "labels current"
    exit 0
fi

log "relabelling ${DATA} (policy or file contexts changed)"
# Older slots kept persistent overlay upper directories under
# ${DATA}/overlays, labelled before each mount; a layer must never be
# relabelled underneath a live overlay. The pre-init deletes that tree at
# boot, so the exclusion applies only if it is still present.
exclude=""
[ -d "${DATA}/overlays" ] && exclude="-e ${DATA}/overlays"
# shellcheck disable=SC2086  # $exclude is intentionally split into -e <path>
restorecon -R -F $exclude "$DATA"
printf '%s\n' "$want" > "${STAMP}.new"
mv -f "${STAMP}.new" "$STAMP"
restorecon -F "$STAMP"
log "done"
