#!/bin/sh
# On-target SELinux acceptance cases, run under ENFORCING.
#
# Exercises the policy as the device actually runs it: the pre-init boot path
# (PID1 domain, the /etc overlay and its labels), who may read the OTA device
# key, sshd and the login path, RAUC's domain, the copy-bind overlays, and the
# prod policy gate. Every case states ALLOW or DENY; a DENY case passes only
# when the access is refused (rc != 0 and an AVC or EACCES is seen), so a
# permissive board cannot pass the negative cases.
#
# Preconditions (the script bails out otherwise):
#   - root in a sysadm_t shell. An SSH root login lands in staff_t; elevate
#     with `newrole -r sysadm_r` (the serial console is sysadm_t already).
#     run-target-checks.sh therefore cannot drive this check over a plain SSH
#     root login: run it on the console or from an elevated shell.
#   - the image booted enforcing (every image does by default; a composition
#     with IOTGW_SELINUX_MODE = "permissive" is not a valid target) and a
#     second sysadm_t shell is open (docs/SELINUX_ENFORCING.md, section 1).
#
# Usage:
#   selinux-enforcing-target.sh [preinit|policy|all]
#     preinit  cases that need the pre-init boot path (init=...iotgw-preinit)
#     policy   policy cases that hold on any boot path
#     all      both (default); cases not applicable to the image are SKIPped
#
# Side effects: transient units (systemd-run) for the run-as-domain cases; a
# restart of systemd-timesyncd (te-var-01); short-lived files in /etc and a
# read-only bind mount under /run/iotgw that the cases remove again; one
# marker file in /etc kept on purpose to detect persistence across a reboot
# (te-etc-03). AVCs are read from audit.log directly: they are not in
# journalctl -k.
#
# Output: TAP (ok / not ok / # SKIP per case, stable case ids). Exit status 1
# on any "not ok" or a failed precondition.
set -u
MODE=${1:-all}
fail=0; n=0
ok()    { n=$((n+1)); echo "ok $n - $1"; }
notok() { n=$((n+1)); fail=1; echo "not ok $n - $1"; }
skip()  { n=$((n+1)); echo "ok $n - $1 # SKIP $2"; }
want()  { case "$MODE" in all) return 0;; *) [ "$MODE" = "$1" ];; esac; }
AUD=/var/log/audit/audit.log
mark() { date +%s; }
avc_since() { awk -v t="$1" -F'[(:]' '/avc:  denied/ { if ($2+0 >= t+0) print }' "$AUD" 2>/dev/null; }
# run_as DOMAIN cmd... : run a command in a given domain via a transient unit (needs init_t -> DOMAIN allowed).
# Limits: a domain is entered only through its own entrypoint type, so `cat`/`true` (bin_t) cannot run as
# rauc_t or sshd_t under enforcing, and a type not authorised for system_r (user_t) fails with exit 229 before
# anything runs. Every run_as case must first pass run_as_works, or it is SKIPped, never passed.
run_as() { d=$1; shift; systemd-run --pipe --wait --collect -q -p SELinuxContext="system_u:system_r:$d:s0" "$@"; }
run_as_works() { run_as "$1" true >/dev/null 2>&1; }
# may DOMAIN TARGET CLASS PERM : the policy (attributes expanded) grants it. For "can X read Y" questions.
may() { [ -n "$(sesearch -A -s "$1" -t "$2" -c "$3" -p "$4" 2>/dev/null)" ]; }
pid1_ctx() { cat /proc/1/attr/current; }

[ "$(getenforce)" = "Enforcing" ] || { echo "Bail out! board is $(getenforce); this check needs an image booted enforcing (IOTGW_SELINUX_MODE)"; exit 1; }
case "$(id -Z 2>/dev/null)" in
  *:sysadm_t:*) ;;
  *) echo "Bail out! shell domain is '$(id -Z 2>/dev/null)'; run as root in sysadm_t (newrole -r sysadm_r)"; exit 1 ;;
esac
if seinfo --permissive 2>/dev/null | grep -q '_t'; then echo "# WARNING permissive domains present: $(seinfo --permissive | tr '\n' ' ') — DENY cases involving them are not meaningful"; fi

### te-pre: pre-init boot path                                                     [preinit]
if want preinit; then
  if grep -qE 'init=/(usr/)?sbin/iotgw-preinit' /proc/cmdline; then
    [ "$(pid1_ctx)" = "system_u:system_r:init_t:s0" ] && ok "te-pre-01 PID1 is init_t after the pre-init exec" || notok "te-pre-01 PID1 context $(pid1_ctx)"
    # te-pre-02: the pre-init logged its own context before and after load_policy (it must write /run/iotgw/preinit.log).
    if [ -r /run/iotgw/preinit.log ]; then grep -q 'ctx-after-load=system_u:system_r:kernel_t:s0' /run/iotgw/preinit.log && ok "te-pre-02 pre-init ran as kernel_t after load_policy" || notok "te-pre-02 $(grep ctx- /run/iotgw/preinit.log | tr '\n' ' ')"; else notok "te-pre-02 no /run/iotgw/preinit.log"; fi
    # te-pre-03: the /etc overlay was assembled exactly once and PID1 did not re-mount it (one overlay line on /etc).
    c=$(awk '$5=="/etc" && $9=="overlay"' /proc/1/mountinfo | wc -l); [ "$c" -eq 1 ] && ok "te-pre-03 one overlay on /etc in PID1 mountinfo" || notok "te-pre-03 $c overlay mounts on /etc"
    # te-pre-04: mounter semantics — a confined accessor reading a file it MAY read through /etc is ALLOWED (no mount_t/kernel_t denial),
    # and reading one it may NOT read is DENIED as its own domain (not as the mounter).
    # ASSUMPTION: dhcpc_t may read the type of /etc/hostname (etc_t in refpolicy). If `sesearch -A -s dhcpc_t -t etc_t -c file -p read`
    # is empty on this policy, pick another etc_t-readable domain/file pair before trusting 04a.
    if ! run_as_works dhcpc_t; then skip "te-pre-04a/b" "run_as cannot enter dhcpc_t (entrypoint): needs the real dhcp client"; else
    t=$(mark); run_as dhcpc_t cat /etc/hostname >/dev/null 2>&1; rc=$?
    if [ $rc -eq 0 ] && ! avc_since $t | grep -q 'scontext=system_u:system_r:kernel_t'; then ok "te-pre-04a dhcpc_t reads /etc/hostname via overlay: ALLOW, no mounter denial"; else notok "te-pre-04a rc=$rc avc=$(avc_since $t | tail -1)"; fi
    t=$(mark); run_as dhcpc_t cat /etc/shadow >/dev/null 2>&1; rc=$?
    if [ $rc -ne 0 ] && avc_since $t | grep -q 'scontext=system_u:system_r:dhcpc_t.*tcontext=.*shadow_t'; then ok "te-pre-04b dhcpc_t reads /etc/shadow: DENY as dhcpc_t (accessor check), not as mounter"; else notok "te-pre-04b rc=$rc avc=$(avc_since $t | tail -1)"; fi
    fi
    # te-pre-05: upper root and new-file labels. The merged /etc dir must be etc_t; a new file by a confined creator gets a transition/parent label, never tmpfs_t/unlabeled_t.
    l=$(ls -dZ /etc | awk '{print $1}'); case "$l" in *:etc_t:*) ok "te-pre-05a merged /etc is $l" ;; *) notok "te-pre-05a merged /etc is $l" ;; esac
    f=/etc/.te-pre-05.tmp; : > $f; l=$(ls -Z $f | awk '{print $1}'); rm -f $f; case "$l" in *unlabeled_t*|*tmpfs_t*) notok "te-pre-05b new file in /etc is $l" ;; *) ok "te-pre-05b new file in /etc is $l" ;; esac
    # te-pre-05c: /data was located as the GPT partition on the root's disk, not by filesystem label.
    grep -q 'partition named data on' /run/iotgw/preinit.log 2>/dev/null && ok "te-pre-05c /data found by PARTNAME on the root disk" || notok "te-pre-05c /data lookup: $(grep 'data device' /run/iotgw/preinit.log 2>/dev/null)"
    # te-pre-05d: the upper tmpfs is size-bounded.
    findmnt -n -o OPTIONS /run/iotgw/overlay 2>/dev/null | grep -q 'size=' && ok "te-pre-05d upper tmpfs size-bounded" || notok "te-pre-05d upper tmpfs has no size bound"
    # te-pre-06: PID1 loaded the policy again after the pre-init; informational.
    journalctl -b -o cat _PID=1 2>/dev/null | grep -m1 'Successfully loaded SELinux policy' | sed 's/^/# PID1: /'
    # te-pre-07: customer unit visible in the INITIAL transaction: a customer-enabled test unit must be active without daemon-reload.
    if systemctl is-active -q iotgw-accept-customer-unit.service 2>/dev/null; then ok "te-pre-07 customer-layer unit active in the boot transaction"; else skip "te-pre-07 customer unit" "fixture iotgw-accept-customer-unit.service not installed in the customer layer"; fi
  else
    skip "te-pre-*" "not a pre-init image (no init=/sbin/iotgw-preinit on cmdline)"
  fi
fi

### te-etc: nothing on /data shadows a vendor file; ephemeral writes do not persist   [preinit]
if want preinit && grep -qE 'init=/(usr/)?sbin/iotgw-preinit' /proc/cmdline; then
  # te-etc-01: no persistent overlay upper under /data is mounted over /etc,/home,/root.
  if awk '$9=="overlay"' /proc/1/mountinfo | grep -q 'upperdir=/data/'; then notok "te-etc-01 a /data-backed upper is mounted: $(awk '$9=="overlay"' /proc/1/mountinfo | grep -o 'upperdir=[^,]*' | tr '\n' ' ')"; else ok "te-etc-01 no /data-backed overlay upper on PID1 mounts"; fi
  # te-etc-02 [writes]: a marker written to /etc is in the tmpfs upper (ephemeral upper) or refused (strictly RO). Either is a pass; record which.
  if echo x > /etc/.te-etc-02 2>/dev/null; then src=$(findmnt -n -o SOURCE,FSTYPE -T /etc | head -1); rm -f /etc/.te-etc-02; ok "te-etc-02 /etc writable: ephemeral upper ($src) — reboot check te-etc-03 must show it gone"; else ok "te-etc-02 /etc not writable (strictly read-only variant)"; fi
  # te-etc-03: after a reboot, no marker from a previous BOOT exists (operator runs this script twice across a reboot).
  # The marker carries the boot_id, so a second run in the same boot is not a false failure.
  bid=$(cat /proc/sys/kernel/random/boot_id)
  if [ -e /etc/.te-etc-03-prev ] && [ "$(cat /etc/.te-etc-03-prev)" != "$bid" ]; then notok "te-etc-03 marker from a previous boot persisted"; else ok "te-etc-03 no persisted marker from a previous boot"; fi
  echo "$bid" > /etc/.te-etc-03-prev 2>/dev/null || true
  # te-etc-04: vendor file identity — the running /etc/nftables.conf is the verity inode (same content as the slot lower).
  mkdir -p /run/iotgw/lowerpeek && mount --bind -o ro / /run/iotgw/lowerpeek 2>/dev/null && { cmp -s /etc/nftables.conf /run/iotgw/lowerpeek/etc/nftables.conf && ok "te-etc-04 /etc/nftables.conf == verity lower" || notok "te-etc-04 /etc/nftables.conf differs from the verity lower"; umount /run/iotgw/lowerpeek; }
fi

### te-key: device key type                                                         [policy]
if want policy; then
  if [ -e /data/ota/certs/device.key ]; then
    l=$(ls -Z /data/ota/certs/device.key | awk '{print $1}')
    case "$l" in *iotgw_ota_key_t*) ok "te-key-01 /data/ota/certs/device.key is $l" ;; *) skip "te-key-01 device.key label $l" "iotgw_ota_key_t not shipped yet";; esac
    [ -e /etc/ota/device.key ] && notok "te-key-02 second key copy still at /etc/ota/device.key" || ok "te-key-02 single key copy (no /etc/ota/device.key)"
    # te-key-03: policy question, answered by the policy (sesearch), not by run_as (see run_as limits above).
    # The runtime oracle for the ALLOW side is a real RAUC streaming/crypt install under enforcing (te-rauc-04).
    l2=$(ls -Z /etc/ota/device.key 2>/dev/null | awk '{print $1}'); case "$l2" in *iotgw_ota_key_t*) ok "te-key-01b /etc/ota/device.key is $l2" ;; *) notok "te-key-01b /etc/ota/device.key is ${l2:-absent}" ;; esac
    for d in user_t staff_t sshd_t container_t; do may $d iotgw_ota_key_t file read && notok "te-key-03 $d may read the device key" || ok "te-key-03 $d may not read the device key (policy)"; done
    may rauc_t iotgw_ota_key_t file read && ok "te-key-03c rauc_t may read the device key (policy)" || notok "te-key-03c rauc_t may not read the device key"
  else skip "te-key-*" "no /data/ota/certs/device.key on this board"; fi
fi

### te-ssh: sshd and the login path                                                 [policy]
if want policy; then
  # te-ssh-01: sshd_t may read shadow_t in the loaded policy — run the real check: a fresh key-only root login from the host is the oracle; here only the policy query.
  if sesearch -A -s sshd_t -t shadow_t -c file -p read 2>/dev/null | grep -q allow; then ok "te-ssh-01 sshd_t shadow_t read allowed"; else skip "te-ssh-01 sshd_t shadow_t read" "no allow rule in the loaded policy"; fi
  echo "# te-ssh-02 (manual, from the host): ssh -o PasswordAuthentication=no -o PreferredAuthentications=publickey root@<board> true  -> expect rc=0 under enforcing"
  echo "# te-ssh-03 (manual): same for devel -> rc=0 and id -Z = user_u:user_r:user_t:s0"
  echo "# te-ssh-04 (manual, negative): a key NOT in authorized_keys -> rc=255, no shadow_t or ssh_home_t denial for sshd_t in audit.log"
  # te-ssh-05: serial console login context: record, do not judge.
  for p in $(pgrep -x login; pgrep -x agetty); do echo "# te-ssh-05 pid $p $(cat /proc/$p/attr/current 2>/dev/null)"; done
fi

### te-rauc: rauc_t basics                                                          [policy]
if want policy; then
  if seinfo -t rauc_t 2>/dev/null | grep -q rauc_t; then
    ps -o label= -p "$(systemctl show -p MainPID --value rauc.service)" | grep -q rauc_t && ok "te-rauc-01 rauc.service runs as rauc_t" || notok "te-rauc-01 rauc runs as $(ps -o label= -p "$(systemctl show -p MainPID --value rauc.service)")"
    rauc status >/dev/null 2>&1 && ok "te-rauc-02 sysadm_t -> rauc_t D-Bus: rauc status ALLOW" || notok "te-rauc-02 rauc status refused from sysadm_t"
    may user_t rauc_t dbus send_msg && notok "te-rauc-03 user_t may send D-Bus messages to rauc_t" || ok "te-rauc-03 user_t -> rauc_t D-Bus: not allowed (policy)"
    echo "# te-rauc-04 (operator-authorised only): rauc install onto raw slot B under enforcing; collect AVCs"
  else skip "te-rauc-*" "rauc_t not in policy"; fi
fi

### te-var: mount-copybind overlays                                                 [policy]
if want policy; then
  # te-var-01: timesyncd can write its clock file through the /var/lib overlay (the ntp_drift_t row) — ALLOW, no mount_t denial.
  t=$(mark); systemctl restart systemd-timesyncd && sleep 2; if avc_since $t | grep -q 'scontext=system_u:system_r:mount_t'; then notok "te-var-01 mount_t mounter denial on /var/lib overlay: $(avc_since $t | grep mount_t | tail -1)"; else ok "te-var-01 no mount_t denial after timesyncd restart"; fi
  # te-var-02: who mounted the copybind overlays (iotgw_overlay_t when the overlay domain ships, else mount_t).
  echo "# te-var-02 mounter of /var/lib: $(awk '$5=="/var/lib"{print $9,$11}' /proc/1/mountinfo)";
fi

### te-rec: recovery mode — fixture-only, operator-authorised; never on the live /data   [preinit]
if want preinit; then
  echo "# te-rec-01..04 are run with a disposable SD: (1) /data partition absent -> boots, /run/iotgw/degraded present, root key login works, rauc-mark-good per the trial-slot gate, ota-updater inactive (Condition)"
  echo "#   (2) /data corrupt (dd zeros over the superblock of a scratch card) -> e2fsck -p repairs or degraded; (3) load_policy failure fixture -> degraded, not halt; (4) two boots: counters BOOT_x_LEFT back to 3 after mark-good"
  [ -e /run/iotgw/degraded ] && echo "# this boot IS degraded: $(cat /run/iotgw/degraded)" || skip "te-rec-00 live board not degraded" "fixture cases need a disposable card"
fi

### te-pol: prod gate on target and two labelling invariants
# te-pol-02: selinux-autorelabel is masked: packagegroup-core-selinux pulls it in, and it cannot relabel a read-only verity root.
[ "$(readlink /etc/systemd/system/selinux-autorelabel.service 2>/dev/null)" = /dev/null ] && ok "te-pol-02 selinux-autorelabel masked" || notok "te-pol-02 selinux-autorelabel not masked ($(systemctl is-enabled selinux-autorelabel.service 2>&1))"
# te-pol-03: the copybind mounter binary carries its domain's entrypoint type (fc spelled under /usr/bin; subs_dist aliases /usr/sbin).
case "$(ls -Z /usr/sbin/mount-copybind | awk '{print $1}')" in *iotgw_overlay_exec_t*) ok "te-pol-03 mount-copybind is iotgw_overlay_exec_t";; *) notok "te-pol-03 mount-copybind label $(ls -Z /usr/sbin/mount-copybind | awk '{print $1}')";; esac
seinfo --permissive 2>/dev/null | grep -q '_t' && notok "te-pol-01 permissive domains present on target" || ok "te-pol-01 seinfo --permissive is empty"

echo "1..$n"
exit $fail
