#!/bin/sh
# Host-side acceptance checks against a built SELinux policy store.
#
# Asserts properties of the policy the image actually ships, not of its
# sources: domain transitions the pre-init design relies on, the permissive
# domain allowlist, who may read the OTA device key, and that the layer's
# file_contexts additions label what they are meant to label.
#
# Usage:
#   scripts/selinux/policy-checks-host.sh <store-root> [layer-dir]
#
#   <store-root> must contain var/lib/selinux/mcs/active/modules/100/*/cil and
#   etc/selinux/mcs/contexts/files/. Either extract it from the built policy
#   packages (needs rpm2cpio, cpio; deploy path depends on MACHINE):
#     D=$(mktemp -d)
#     for r in build/tmp/deploy/rpm/<machine>/refpolicy-mcs-{,dev-}2*.rpm; do
#         rpm2cpio "$r" | (cd "$D" && cpio -idm --quiet)
#     done
#     scripts/selinux/policy-checks-host.sh "$D"
#   or copy it read-only from a running device:
#     ssh root@<gw> 'tar -C / -cf - var/lib/selinux/mcs/active/modules \
#         etc/selinux/mcs/contexts/files' | tar -x -C "$D"
#
#   [layer-dir] defaults to meta-iot-gateway next to this script's repo; it
#   supplies the file_contexts .subs/.local sources and the distro allowlist.
#   matchpathcon is optional: the precedence cases skip without it.
#
# Output: TAP (ok / not ok / # SKIP per case, stable case ids). Exit status 1
# if any case is "not ok" or the store is missing, 0 otherwise.
#
# Environment overrides:
#   IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED  permissive-domain allowlist
#       (default: the value in the distro include)

set -u
ROOT=${1:?usage: policy-checks-host.sh <store-root> [layer-dir]}
LAYER=${2:-$(dirname -- "$0")/../../meta-iot-gateway}
MODS="$ROOT/var/lib/selinux/mcs/active/modules/100"
FCDIR="$ROOT/etc/selinux/mcs/contexts/files"
POLFILES="$LAYER/recipes-security/refpolicy/files"
fail=0; n=0
ok()     { n=$((n+1)); echo "ok $n - $1"; }
notok()  { n=$((n+1)); fail=1; echo "not ok $n - $1"; }
skip()   { n=$((n+1)); echo "ok $n - $1 # SKIP $2"; }
cil() { if file "$MODS/$1/cil" | grep -q bzip2; then bzcat "$MODS/$1/cil"; else cat "$MODS/$1/cil"; fi; }
allcil() { for m in "$MODS"/*; do cil "$(basename "$m")"; done; }

[ -d "$MODS" ] || { echo "Bail out! no module store under $MODS"; exit 1; }
[ -d "$POLFILES" ] || { echo "Bail out! no layer policy sources under $POLFILES"; exit 1; }

# host-pol-01: the only process typetransitions FROM kernel_t are the known set;
# in particular none to mount_t or a shell domain, so a pre-init running as
# kernel_t keeps kernel_t across `mount` and `sh`.
tt=$(allcil | grep -o 'typetransition kernel_t [a-z_]* process [a-z_]*' | awk '{print $3"->"$5}' | sort -u)
if echo "$tt" | grep -q 'mount_exec_t\|shell_exec_t\|bin_t->'; then
  notok "host-pol-01 kernel_t process transitions include mount/shell: $(echo $tt | tr '\n' ' ')"
else
  ok "host-pol-01 no kernel_t->mount_t/shell transition (have: $(echo $tt | tr '\n' ' '))"
fi

# host-pol-02: no permissive domains in the built store beyond the
# allowlist (same semantics as iotgw_rootfs_selinux_permissive_gate). A
# permissive domain stays permissive under global enforcing, so the list is
# expected to be empty.
EXPECTED=${IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED-$(sed -n 's/^IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED ?= "\(.*\)"/\1/p' "$LAYER/conf/distro/include/iotgw-common.inc" 2>/dev/null)}
found=$(allcil | sed -n 's/^ *(typepermissive \([A-Za-z0-9_]*\))/\1/p' | sort -u | tr '\n' ' ')
unexpected=""; for d in $found; do case " $EXPECTED " in *" $d "*) ;; *) unexpected="$unexpected $d";; esac; done
if [ -n "$unexpected" ]; then notok "host-pol-02 permissive domain(s) outside the allowlist:$unexpected (allowlist: '$EXPECTED')"
elif [ -n "$found" ]; then ok "host-pol-02 only allowlisted permissive domains: $found(allowlist '$EXPECTED'; expected empty)"
else ok "host-pol-02 no typepermissive statements"; fi

# host-pol-03: kernel_t is files/filesystem unconfined (the pre-init mounts
# as kernel_t and must not need per-type rules).
for a in files_unconfined_type filesystem_unconfined_type; do
  if cil base | grep -q "typeattributeset $a (kernel_t"; then ok "host-pol-03 kernel_t in $a"; else notok "host-pol-03 kernel_t NOT in $a"; fi
done

# host-pol-04: kernel_t -> init_t on exec of init_exec_t (PID1 lands in init_t
# after the pre-init execs it).
if cil init | grep -q 'typetransition kernel_t init_exec_t process init_t'; then
  ok "host-pol-04 kernel_t->init_t on init_exec_t"
else
  notok "host-pol-04 missing kernel_t->init_t transition"
fi

# host-pol-05: refpolicy lets sshd_t read shadow_t only through the PAM boolean
# branch; whether an unconditional allow ships is a local policy decision
# (docs/SELINUX_ENFORCING.md, sshd and passwords). Report the state, do not judge.
if allcil | grep -q 'allow sshd_t shadow_t (file (.*read'; then
  ok "host-pol-05 sshd_t shadow_t read present (unconditional allow shipped)"
else
  skip "host-pol-05 sshd_t shadow_t read" "no unconditional allow in this store"
fi

# host-pol-06: when the OTA key type exists, only the intended domains may
# read it; login domains must not.
if allcil | grep -q '(type iotgw_ota_key_t)'; then
  readers=$(allcil | grep -o 'allow [a-z_]* iotgw_ota_key_t (file ([^)]*read' | awk '{print $2}' | sort -u | tr '\n' ' ')
  case " $readers " in *" sshd_t "*|*" staff_t "*|*" user_t "*) notok "host-pol-06 forbidden reader of iotgw_ota_key_t: $readers" ;; *) ok "host-pol-06 iotgw_ota_key_t readers: $readers" ;; esac
  # A file_type attribute makes the type readable by every holder of
  # files_read_all_files; those holders are not listed above.
  allcil | grep -q 'typeattributeset [a-z_]*file_type[a-z_]* (.*iotgw_ota_key_t' && echo "# note: iotgw_ota_key_t carries a file_type attribute; verify files_read_all_files holders (initrc_t/kernel_t/init_t are intended)"
else
  skip "host-pol-06 iotgw_ota_key_t readers" "type not in store"
fi

# host-fc-01: the layer's file_contexts.local must take precedence over the
# policy's own entry for the device key, and the .subs alias must give the
# /data SSH host keys sshd_key_t. Evaluated with the shipped file_contexts
# plus the layer's .subs/.local.
if command -v matchpathcon >/dev/null 2>&1; then
  T=$(mktemp -d); cp "$FCDIR/file_contexts" "$T/"; cp "$FCDIR/file_contexts.homedirs" "$T/" 2>/dev/null
  cp "$POLFILES/iotgw-file_contexts.subs" "$T/file_contexts.subs"
  cp "$POLFILES/iotgw-file_contexts.local" "$T/file_contexts.local"
  cp "$FCDIR/file_contexts.subs_dist" "$T/" 2>/dev/null
  key=$(matchpathcon -f "$T/file_contexts" /data/ota/certs/device.key 2>/dev/null | awk '{print $2}')
  sshk=$(matchpathcon -f "$T/file_contexts" /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
  echo "# device.key -> $key ; ssh host key -> $sshk"
  case "$sshk" in *sshd_key_t*) ok "host-fc-01a /data/ssh alias gives sshd_key_t" ;; *) notok "host-fc-01a /data/ssh -> $sshk" ;; esac
  if grep -q 'iotgw_ota_key_t' "$T/file_contexts.local"; then
    case "$key" in *iotgw_ota_key_t*) ok "host-fc-01b device.key -> iotgw_ota_key_t via .local" ;; *) notok "host-fc-01b device.key -> $key (.local precedence lost)" ;; esac
  else skip "host-fc-01b device.key type" "no iotgw_ota_key_t line in .local (device.key -> $key)"; fi
  rm -rf "$T"
else
  skip "host-fc-01 matchpathcon precedence" "matchpathcon not installed on this host; run on target"
fi

# host-fc-02: the type /etc/machine-id carries in the shipped file_contexts,
# which the /data/machine-id alias inherits.
mid=$(grep -E '^/etc/machine-id\b' "$FCDIR/file_contexts" | awk '{print $NF}' | head -1)
if [ -n "$mid" ]; then ok "host-fc-02 /etc/machine-id -> $mid"
else skip "host-fc-02 /etc/machine-id" "no explicit entry: inherits /etc(/.*)? etc_t"; fi

# host-fc-03: the layer's .subs and .local are what the package ships (the
# bbappend copies them verbatim). A mismatch also means the store is from an
# older build than the layer tree.
for f in subs local; do
  if cmp -s "$POLFILES/iotgw-file_contexts.$f" "$FCDIR/file_contexts.$f"; then ok "host-fc-03 shipped file_contexts.$f == layer"; else notok "host-fc-03 shipped file_contexts.$f differs from layer"; fi
done

# host-fc-04: every binary spec in the iotgw module must be spelled under
# /usr/bin. subs_dist aliases /sbin and /usr/sbin onto /usr/bin, so a
# /usr/sbin/... spec never matches at labelling time and the binary falls
# back to bin_t, losing its entrypoint type.
bad=$(grep -E '^/(usr/)?sbin/' "$POLFILES/policy/iotgw.fc" | grep -v '^#' || true)
if [ -z "$bad" ]; then ok "host-fc-04 no /sbin or /usr/sbin specs in iotgw.fc"
else notok "host-fc-04 sbin-spelled specs (aliased away by subs_dist): $(echo $bad)"; fi
if grep -q '^/usr/sbin /usr/bin' "$FCDIR/file_contexts.subs_dist" 2>/dev/null; then ok "host-fc-04b subs_dist aliases /usr/sbin -> /usr/bin (as assumed)"; else notok "host-fc-04b subs_dist no longer aliases /usr/sbin -> /usr/bin; re-check the .fc spelling rule"; fi

echo "1..$n"
exit $fail
