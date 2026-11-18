#!/bin/bash
# Rootless container acceptance check for the IoT Gateway distro (iotgw).
#
# Runs ON the gateway, as root, and produces evidence from the board that the
# container stack is the rootless one: the iotgw-ctr principal exists with the
# ids the static tables fix, its subordinate ranges are present, systemd-logind
# lingers it into a running user manager in the expected SELinux domain, a
# container started through that manager runs as the principal (no uid 0 on
# the host, ids mapped onto the subordinate range, seccomp filter active,
# pasta networking, store owned by the principal with container labels), the
# rootful engine has no socket, service or mount, and the run leaves no AVC
# denial behind.
#
# The payload is started the way a workload would be: a transient Quadlet
# unit is written to the principal's Quadlet directory (on the tmpfs /etc
# overlay, gone at the next reboot), the principal's user manager is
# restarted so its generator turns it into a service, and the service is
# inspected from outside. Nothing is run through `sudo -u`/`runuser`: from a
# root shell that keeps the admin's SELinux context and would exercise the
# rootful engine domain instead of the principal's.
#
# Usage:
#   # On target directly (with lib/target-check.sh copied to ../lib):
#   sudo ./rootless-acceptance-target.sh
#
#   # From host over SSH (no copy needed):
#   cat scripts/lib/target-check.sh scripts/containers/rootless-acceptance-target.sh | ssh <gw> 'sudo bash -s'
#   # Over SSH, root lands in staff_t, which may not read audit.log: the AVC
#   # section then SKIPs by design. Run from the serial console (sysadm_t)
#   # for an AVC result.
#
# Environment:
#   IOTGW_CTR_TEST_IMAGE      Image the payload runs (default docker.io/library/alpine:latest).
#                             Pulled by the unit when absent from the store, so the
#                             device needs registry access unless the image is loaded.
#   IOTGW_CTR_TEST_IMAGE_TAR  A `podman save` archive on the device, readable by the
#                             principal (put it under /home/iotgw-ctr/.local/share/containers, whose label the engine domain may read); loaded into
#                             its store by a helper unit before the payload starts,
#                             for an offline run.
#   IOTGW_CTR_START_TIMEOUT   Seconds to wait for the payload (default 150; a pull
#                             counts against it).
#   IOTGW_CTR_KEEP=1          Leave the fixture units and the container running for
#                             inspection (clean up with the printed commands).
#
# Exit status: 0 if no check FAILed.
#
# Pairs with:
#   (the former rootful container smoke is retired; this script covers the engine)
#   scripts/selinux/selinux-enforcing-target.sh — policy trial

set -u

# Reporting helpers: streamed ahead of this script by run-target-checks.sh,
# otherwise sourced from the repo layout.
if ! command -v say_pass >/dev/null 2>&1; then
    # shellcheck source=../lib/target-check.sh
    . "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../lib/target-check.sh" || exit 2
fi
say_info() { printf '       %s\n' "$1"; }
evidence() {
    local label="$1"; shift
    printf '  --- %s: %s\n' "$label" "$*"
    "$@" 2>&1 | sed 's/^/      /'
}

CTR_USER=iotgw-ctr
CTR_UID=968
CTR_GID=968
CTR_HOME=/home/$CTR_USER
SUBID_BASE=200000
SUBID_COUNT=65536
STORE=$CTR_HOME/.local/share/containers
QUADLET_DIR=/etc/containers/systemd/users/$CTR_UID
USER_UNIT_DIR=/etc/systemd/user
FIXTURE=iotgw-ctr-accept
IMAGE="${IOTGW_CTR_TEST_IMAGE:-docker.io/library/alpine:latest}"
IMAGE_TAR="${IOTGW_CTR_TEST_IMAGE_TAR:-}"
START_TIMEOUT="${IOTGW_CTR_START_TIMEOUT:-150}"
KEEP="${IOTGW_CTR_KEEP:-0}"
AUD=/var/log/audit/audit.log

if [ "$(id -u)" != 0 ]; then
    echo "run as root (sudo)"; exit 2
fi

SELINUX=0
if [ -d /sys/fs/selinux ] && command -v getenforce >/dev/null 2>&1; then
    SELINUX=1
    MODE=$(getenforce)
fi
MY_CTX=$(id -Z 2>/dev/null || echo none)
AUDIT_READABLE=0
case "$MY_CTX" in *:sysadm_t:*) [ -r "$AUD" ] && AUDIT_READABLE=1 ;; esac
# avc_since <epoch> [<skip-from> <skip-to>]: denials from <epoch> on, leaving out a window.
avc_since() { awk -v t="$1" -v a="${2:-0}" -v b="${3:-0}" -F'[(:]' '/avc:  denied/ { e = $2 + 0; if (e >= t + 0 && !(a + 0 > 0 && e >= a + 0 && e <= b + 0)) print }' "$AUD" 2>/dev/null; }
label_of() { ls -dZ "$1" 2>/dev/null | awk '{print $1}'; }
proc_label() { tr -d '\000' < "/proc/$1/attr/current" 2>/dev/null; }

# ---------------------------------------------------------------------------
section "0. Context"
say_info "SELinux: $([ $SELINUX = 1 ] && echo "$MODE" || echo "not enabled"); this shell: $MY_CTX"
say_info "audit log readable from here: $([ $AUDIT_READABLE = 1 ] && echo yes || echo "no (AVC section skips)")"
say_info "payload image: $IMAGE${IMAGE_TAR:+ (loaded from $IMAGE_TAR)}"

# ---------------------------------------------------------------------------
section "1. Principal and subordinate ids"
pw=$(getent passwd "$CTR_USER")
if [ -z "$pw" ]; then
    say_fail "principal $CTR_USER exists"
else
    say_pass "principal $CTR_USER exists"
    IFS=: read -r _ _ uid gid _ home shell <<<"$pw"
    [ "$uid" = "$CTR_UID" ] && say_pass "uid is $CTR_UID" || say_fail "uid is $uid, expected $CTR_UID"
    [ "$gid" = "$CTR_GID" ] && say_pass "gid is $CTR_GID" || say_fail "gid is $gid, expected $CTR_GID"
    [ "$home" = "$CTR_HOME" ] && say_pass "home is $CTR_HOME" || say_fail "home is $home, expected $CTR_HOME"
    case "$shell" in */nologin|*/false) say_pass "shell is non-login ($shell)" ;; *) say_fail "shell is $shell (login shell)" ;; esac
fi
g=$(getent group "$CTR_USER" | cut -d: -f3)
[ "$g" = "$CTR_GID" ] && say_pass "group $CTR_USER is gid $CTR_GID" || say_fail "group $CTR_USER gid is '${g:-absent}', expected $CTR_GID"
for f in subuid subgid; do
    if grep -qx "$CTR_USER:$SUBID_BASE:$SUBID_COUNT" /etc/$f 2>/dev/null; then
        say_pass "/etc/$f has $CTR_USER:$SUBID_BASE:$SUBID_COUNT"
    else
        say_fail "/etc/$f lacks $CTR_USER:$SUBID_BASE:$SUBID_COUNT (has: $(tr '\n' ' ' < /etc/$f 2>/dev/null))"
    fi
    # Every range in the file must be disjoint from the principal's.
    overlap=$(awk -F: -v b=$SUBID_BASE -v n=$SUBID_COUNT -v u="$CTR_USER" \
        '$1 != u && $2+0 < b+n && $2+$3 > b { print $0 }' /etc/$f 2>/dev/null)
    [ -z "$overlap" ] && say_pass "/etc/$f ranges disjoint from the principal's" || say_fail "/etc/$f overlaps the principal's range: $overlap"
done
for h in newuidmap newgidmap; do
    p=$(command -v $h 2>/dev/null)
    if [ -n "$p" ] && [ -u "$p" ] && [ "$(stat -c %u "$p")" = 0 ]; then say_pass "$h is setuid root ($p)"
    else say_fail "$h setuid root (${p:-absent})"; fi
done
check "pasta present" command -v pasta
if [ -c /dev/net/tun ]; then say_pass "/dev/net/tun present"; else say_fail "/dev/net/tun present"; fi
if [ -d /sys/module/tun ] || grep -qx 'CONFIG_TUN=y' <(zcat /proc/config.gz 2>/dev/null); then say_pass "tun driver loaded or built in"
else say_fail "tun driver not loaded (modules-load.d/iotgw-containers.conf)"; fi

# ---------------------------------------------------------------------------
section "2. No rootful engine"
for u in podman.socket podman.service; do
    st=$(systemctl is-enabled "$u" 2>/dev/null || true)
    case "$st" in enabled|enabled-runtime) say_fail "$u is $st" ;; *) say_pass "$u is ${st:-absent} (not enabled)" ;; esac
    if systemctl is-active -q "$u" 2>/dev/null; then say_fail "$u is active"; else say_pass "$u not active"; fi
done
if [ -S /run/podman/podman.sock ]; then say_fail "/run/podman/podman.sock exists"; else say_pass "no /run/podman/podman.sock"; fi
if findmnt -n /var/lib/containers >/dev/null 2>&1; then say_fail "/var/lib/containers is a mountpoint (rootful store bind)"; else say_pass "no /var/lib/containers mount"; fi
for u in var-lib-containers.mount iotgw-podman-graphroot-migrate.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then say_fail "$u still shipped"; else say_pass "$u not shipped"; fi
done
# Nothing wants the rootful units.
w=$(find /etc/systemd/system /usr/lib/systemd/system -name 'podman.s*' -path '*.wants/*' 2>/dev/null)
[ -z "$w" ] && say_pass "no .wants link to the rootful podman units" || say_fail "rootful podman units wanted by: $w"

# ---------------------------------------------------------------------------
section "3. Linger and user manager"
if [ -f /var/lib/systemd/linger/$CTR_USER ]; then say_pass "linger marker /var/lib/systemd/linger/$CTR_USER"
else say_fail "linger marker /var/lib/systemd/linger/$CTR_USER"; fi
check_match "loginctl reports Linger=yes" '^Linger=yes$' loginctl show-user "$CTR_USER" -p Linger
if systemctl is-active -q "user@$CTR_UID.service"; then
    say_pass "user@$CTR_UID.service active"
    mgr_pid=$(systemctl show -p MainPID --value "user@$CTR_UID.service")
    if [ "$(ps -o uid= -p "$mgr_pid" | tr -d ' ')" = "$CTR_UID" ]; then say_pass "user manager runs as uid $CTR_UID"
    else say_fail "user manager uid is $(ps -o uid= -p "$mgr_pid")"; fi
    if [ $SELINUX = 1 ]; then
        l=$(proc_label "$mgr_pid")
        case "$l" in user_u:user_r:user_systemd_t:*) say_pass "user manager domain $l" ;; *) say_fail "user manager domain $l (expected user_u:user_r:user_systemd_t)" ;; esac
    fi
else
    say_fail "user@$CTR_UID.service active"
    evidence "user@$CTR_UID status" systemctl status "user@$CTR_UID.service" --no-pager -n 10
fi
if [ -d /run/user/$CTR_UID ] && [ "$(stat -c %u /run/user/$CTR_UID)" = "$CTR_UID" ]; then say_pass "/run/user/$CTR_UID owned by $CTR_UID"
else say_fail "/run/user/$CTR_UID owned by $CTR_UID"; fi
if [ -S /run/user/$CTR_UID/bus ]; then say_pass "user bus socket (cgroup_manager=systemd)"; else say_fail "user bus socket /run/user/$CTR_UID/bus"; fi
# The per-user podman API is not started for the principal.
if [ -S /run/user/$CTR_UID/podman/podman.sock ]; then say_fail "per-user podman API socket present"; else say_pass "no per-user podman API socket"; fi

# ---------------------------------------------------------------------------
section "4. Store on /data"
# A bind shows the device, not /data/home; the pre-init records what it did.
if grep -q '/home bound from /data/home' /run/iotgw/preinit.log 2>/dev/null; then say_pass "/home is bound from /data/home (pre-init log)"
else say_fail "/home bound from /data/home (pre-init log: $(grep -o 'home[^"]*' /run/iotgw/preinit.log 2>/dev/null | tail -1))"; fi
if [ -d "$CTR_HOME" ] && [ "$(stat -c %u:%g:%a "$CTR_HOME")" = "$CTR_UID:$CTR_GID:700" ]; then say_pass "$CTR_HOME is $CTR_UID:$CTR_GID 0700"
else say_fail "$CTR_HOME ownership/mode: $(stat -c %u:%g:%a "$CTR_HOME" 2>/dev/null || echo absent)"; fi
if [ -d "$STORE/storage/tmp" ]; then say_pass "store skeleton $STORE/storage/tmp present"; else say_fail "store skeleton $STORE/storage/tmp present"; fi
if [ $SELINUX = 1 ]; then
    l=$(label_of "$STORE")
    case "$l" in *:container_data_home_t:*) say_pass "store label $l" ;; *) say_fail "store label $l (expected container_data_home_t)" ;; esac
    l=$(label_of "$QUADLET_DIR")
    case "$l" in *:systemd_unit_t:*) say_pass "Quadlet dir label $l" ;; *) say_fail "Quadlet dir label $l (expected systemd_unit_t)" ;; esac
fi
if [ -d "$QUADLET_DIR" ]; then say_pass "Quadlet directory $QUADLET_DIR"; else say_fail "Quadlet directory $QUADLET_DIR"; fi

# ---------------------------------------------------------------------------
section "5. Payload through the principal's user manager"
cleanup_fixture() {
    rm -f "$QUADLET_DIR/$FIXTURE.container" "$USER_UNIT_DIR/$FIXTURE-load.service" \
        "$USER_UNIT_DIR/$FIXTURE-probe.service" "$USER_UNIT_DIR/default.target.wants/$FIXTURE-probe.service"
    rm -f "/run/user/$CTR_UID/$FIXTURE-probe.sh"
    systemctl restart "user@$CTR_UID.service" 2>/dev/null
}
if [ -e "$QUADLET_DIR/$FIXTURE.container" ]; then
    say_fail "fixture $QUADLET_DIR/$FIXTURE.container already present (previous run kept it?)"
    evidence "remove with" echo "rm $QUADLET_DIR/$FIXTURE.container $USER_UNIT_DIR/$FIXTURE-load.service $USER_UNIT_DIR/$FIXTURE-probe.service $USER_UNIT_DIR/default.target.wants/$FIXTURE-probe.service; systemctl restart user@$CTR_UID.service"
    summary
    exit $?
fi
LOAD_UNIT=""
if [ -n "$IMAGE_TAR" ]; then
    if [ -r "$IMAGE_TAR" ]; then
        cat > "$USER_UNIT_DIR/$FIXTURE-load.service" <<EOF
[Unit]
Description=Acceptance fixture: load $IMAGE_TAR into the principal's store
ConditionUser=$CTR_USER
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman load -i $IMAGE_TAR
EOF
        LOAD_UNIT="$FIXTURE-load.service"
        say_info "helper unit $LOAD_UNIT loads the archive before the payload"
    else
        say_fail "IOTGW_CTR_TEST_IMAGE_TAR=$IMAGE_TAR not readable"
    fi
fi
cat > "$QUADLET_DIR/$FIXTURE.container" <<EOF
[Unit]
Description=Acceptance fixture: rootless payload as $CTR_USER
ConditionUser=$CTR_USER
${LOAD_UNIT:+After=$LOAD_UNIT}
${LOAD_UNIT:+Requires=$LOAD_UNIT}

[Container]
Image=$IMAGE
ContainerName=$FIXTURE
Exec=sleep 600

[Service]
Restart=no
TimeoutStartSec=$START_TIMEOUT

[Install]
WantedBy=default.target
EOF
if [ $SELINUX = 1 ]; then
    l=$(label_of "$QUADLET_DIR/$FIXTURE.container")
    say_info "fixture written ($l)"
else
    say_info "fixture written"
fi
T0=$(date +%s)
LISTENERS_BEFORE=$(ss -H -tlne 2>/dev/null | grep -c "uid:$CTR_UID")
systemctl restart "user@$CTR_UID.service"
rc=$?
[ $rc = 0 ] && say_pass "user@$CTR_UID.service restarted with the fixture" || say_fail "user@$CTR_UID.service restart failed (rc=$rc)"

# Wait for the payload's sleep, owned by the principal, started under the fixture.
PAY=""
n=0
while [ "$n" -lt "$START_TIMEOUT" ]; do
    PAY=$(pgrep -u "$CTR_UID" -x sleep | head -1)
    [ -n "$PAY" ] && break
    sleep 1; n=$((n+1))
done
if [ -n "$PAY" ]; then
    say_pass "payload running after ${n}s (pid $PAY)"
else
    say_fail "payload not running within ${START_TIMEOUT}s"
    evidence "fixture unit journal" journalctl -b --no-pager -n 25 "_UID=$CTR_UID"
fi

if [ -n "$PAY" ]; then
    # A1: nothing of the container stack runs as uid 0 on the host.
    # Numeric uid: ps truncates a user name longer than its column to the uid.
    rows=$(ps -eo pid,uid,comm | awk -v u="$CTR_UID" '$3 ~ /^(podman|conmon|crun|pasta|slirp4netns|sleep)$/ && $2 != u')
    [ -z "$rows" ] && say_pass "no container-stack process runs as another uid" || say_fail "container-stack process(es) not owned by uid $CTR_UID: $(echo "$rows" | tr '\n' ';')"
    evidence "stack processes" sh -c "for p in \$(pgrep -x 'podman|conmon|crun|pasta|sleep'); do printf '%s %s %s %s\\n' \"\$p\" \"\$(ps -o uid= -p \$p | tr -d ' ')\" \"\$(ps -o comm= -p \$p)\" \"\$(tr -d '\\000' < /proc/\$p/attr/current 2>/dev/null)\"; done"
    [ "$(ps -o uid= -p "$PAY" | tr -d ' ')" = "$CTR_UID" ] && say_pass "payload host uid is $CTR_UID" || say_fail "payload host uid is $(ps -o uid= -p "$PAY")"
    # A2: id mapping of the container's user namespace.
    if grep -qE "^\s*0\s+$CTR_UID\s+1$" "/proc/$PAY/uid_map" && grep -qE "^\s*1\s+$SUBID_BASE\s+$SUBID_COUNT$" "/proc/$PAY/uid_map"; then
        say_pass "uid_map: 0 -> $CTR_UID, 1.. -> $SUBID_BASE+$SUBID_COUNT"
    else
        say_fail "uid_map unexpected: $(tr -s ' \n' ' ' < "/proc/$PAY/uid_map")"
    fi
    if grep -qE "^\s*0\s+$CTR_GID\s+1$" "/proc/$PAY/gid_map" && grep -qE "^\s*1\s+$SUBID_BASE\s+$SUBID_COUNT$" "/proc/$PAY/gid_map"; then
        say_pass "gid_map: 0 -> $CTR_GID, 1.. -> $SUBID_BASE+$SUBID_COUNT"
    else
        say_fail "gid_map unexpected: $(tr -s ' \n' ' ' < "/proc/$PAY/gid_map")"
    fi
    # Seccomp filter mode 2 on the container process.
    sc=$(awk '/^Seccomp:/ {print $2}' "/proc/$PAY/status")
    [ "$sc" = 2 ] && say_pass "payload Seccomp: 2 (filter active)" || say_fail "payload Seccomp: ${sc:-?} (expected 2)"
    if [ -f /usr/share/containers/seccomp.json ]; then say_pass "seccomp profile shipped at /usr/share/containers/seccomp.json"
    else say_fail "seccomp profile /usr/share/containers/seccomp.json shipped"; fi
    # A4: domains.
    if [ $SELINUX = 1 ]; then
        l=$(proc_label "$PAY")
        case "$l" in *:container_t:s0:c*) say_pass "payload domain $l" ;; *) say_fail "payload domain $l (expected container_t with categories)" ;; esac
        cm=$(pgrep -u "$CTR_UID" -x conmon | head -1)
        if [ -n "$cm" ]; then
            l=$(proc_label "$cm")
            case "$l" in *:podman_user_conmon_t:*) say_pass "conmon domain $l" ;; *) say_fail "conmon domain $l (expected podman_user_conmon_t)" ;; esac
        else
            say_fail "conmon process of the principal found"
        fi
    fi
    # A5: pasta provides the network.
    pp=$(pgrep -u "$CTR_UID" -x pasta | head -1)
    [ -n "$pp" ] && say_pass "pasta running for the container (pid $pp)" || say_fail "pasta process of the principal (default_rootless_network_cmd)"
    if pgrep -x slirp4netns >/dev/null 2>&1; then say_fail "slirp4netns running"; else say_pass "no slirp4netns"; fi
    # A6: the fixture publishes no port, so it adds no listener owned by the principal; a
    # workload that publishes one needs a family-scoped accept rule in nftables.conf.
    ls_=$(ss -H -tlne 2>/dev/null | grep -c "uid:$CTR_UID")
    [ "$ls_" = "$LISTENERS_BEFORE" ] && say_pass "the fixture added no TCP listener owned by uid $CTR_UID ($ls_ from other workloads)" || say_fail "the fixture changed the TCP listeners of uid $CTR_UID: $LISTENERS_BEFORE before, $ls_ now"
    evidence "payload unit journal" journalctl -b --no-pager -n 8 "_SYSTEMD_USER_UNIT=$FIXTURE.service" "_UID=$CTR_UID"
fi

# ---------------------------------------------------------------------------
section "5b. Network reach, confinement and restart, as the principal"
# Run from a user unit for the same reason as the payload. Results go to the
# journal; the addresses are this gateway's own, so a container must reach none.
PROBE_PORT=39222
LOCAL_ADDRS=$(ip -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | tr '\n' ' ')
PROBE=/run/user/$CTR_UID/$FIXTURE-probe.sh
cat > "$PROBE" <<EOF
IMG=$IMAGE
podman run -d --rm --name $FIXTURE-listen --network pasta -p $PROBE_PORT:$PROBE_PORT "\$IMG" sh -c 'while true; do printf probe-ok | nc -l -p $PROBE_PORT >/dev/null 2>&1; done' >/dev/null
sleep 3
echo PROBE_READY
sleep ${IOTGW_CTR_PROBE_WAIT:-6}
if podman run --rm --network pasta "\$IMG" true >/dev/null 2>&1; then echo PROBE_CONTROL ok; else echo PROBE_CONTROL fail; fi
o=\$(podman run --rm "\$IMG" cat /proc/self/attr/current 2>/dev/null | tr -d '\000'); echo "PROBE_BASELINE \${o:-none}"
for a in $LOCAL_ADDRS 127.0.0.1 ::1 host.containers.internal; do
    for p in 22 $PROBE_PORT; do
        if podman run --rm --network pasta "\$IMG" nc -z -w3 "\$a" "\$p" >/dev/null 2>&1; then echo "PROBE_HOST open \$a \$p"; else echo "PROBE_HOST closed \$a \$p"; fi
    done
done
if [ -n "${IOTGW_CTR_EGRESS_PROBE:-}" ]; then
    h=${IOTGW_CTR_EGRESS_PROBE:+${IOTGW_CTR_EGRESS_PROBE%:*}}; p=${IOTGW_CTR_EGRESS_PROBE:+${IOTGW_CTR_EGRESS_PROBE##*:}}
    if podman run --rm --network pasta "\$IMG" nc -z -w5 "\$h" "\$p" >/dev/null 2>&1; then echo PROBE_EGRESS ok; else echo PROBE_EGRESS fail; fi
fi
echo "PROBE_REFUSALS_FROM \$(date +%s)"
for opt in label=disable label=type:spc_user_t label=type:unconfined_t label=type:podman_user_t label=type:user_t label=type:spc_t label=type:container_engine_t; do
    o=\$(podman run --rm --security-opt "\$opt" "\$IMG" cat /proc/self/attr/current 2>/dev/null | tr -d '\000'); echo "PROBE_LABEL \$opt=\${o:-refused}"
done
o=\$(podman run --rm --privileged "\$IMG" cat /proc/self/attr/current 2>/dev/null | tr -d '\000'); echo "PROBE_LABEL privileged=\${o:-refused}"
d=\$HOME/.local/share/containers/$FIXTURE-rootfs
mkdir -p "\$d"
podman create --name $FIXTURE-rf "\$IMG" true >/dev/null 2>&1
podman export $FIXTURE-rf 2>/dev/null | tar -xf - -C "\$d" 2>/dev/null
podman rm $FIXTURE-rf >/dev/null 2>&1
if [ -e "\$d/bin/sh" ]; then echo PROBE_ROOTFS ok; else echo PROBE_ROOTFS fail; fi
o=\$(podman run --rm --security-opt label=disable --rootfs "\$d" /bin/sh -c 'cat /proc/self/attr/current' 2>/dev/null | tr -d '\000'); echo "PROBE_LABEL rootfs-label-disable=\${o:-refused}"
o=\$(podman run --rm --pid=host --rootfs "\$d" /bin/sh -c 'cat /proc/self/attr/current' 2>/dev/null | tr -d '\000'); echo "PROBE_LABEL rootfs-pid-host=\${o:-refused}"
podman unshare rm -rf "\$d" 2>/dev/null
echo "PROBE_REFUSALS_TO \$(( \$(date +%s) + 1 ))"
echo "PROBE_SUBUID_ID \$(podman unshare setpriv --reuid=1000 --regid=1000 --clear-groups id -u 2>/dev/null)"
if podman unshare setpriv --reuid=1000 --regid=1000 --clear-groups timeout 4 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; then echo PROBE_SUBUID open; else echo PROBE_SUBUID closed; fi
echo "PROBE_LISTENER \$(podman inspect -f '{{.State.Running}}' $FIXTURE-listen 2>/dev/null)"
podman stop -t 1 $FIXTURE-listen >/dev/null 2>&1
echo PROBE_DONE
EOF
chown "$CTR_UID:$CTR_UID" "$PROBE"; chmod 0644 "$PROBE"
cat > "$USER_UNIT_DIR/$FIXTURE-probe.service" <<EOF
[Unit]
Description=Acceptance fixture: network and confinement probes
ConditionUser=$CTR_USER
After=$FIXTURE.service
[Service]
Type=oneshot
ExecStart=/bin/sh $PROBE
TimeoutStartSec=420
[Install]
WantedBy=default.target
EOF
mkdir -p "$USER_UNIT_DIR/default.target.wants"
ln -sf "../$FIXTURE-probe.service" "$USER_UNIT_DIR/default.target.wants/$FIXTURE-probe.service"
restorecon -R "$USER_UNIT_DIR" 2>/dev/null
RS=$(date +%s)
systemctl restart "user@$CTR_UID.service"
rc=$?; RE=$(date +%s)
if [ "$rc" = 0 ] && [ $((RE-RS)) -lt 30 ]; then say_pass "user manager restart with a running container took $((RE-RS))s"
else say_fail "user manager restart with a running container: rc=$rc after $((RE-RS))s"; fi
probe_log() { journalctl -b --no-pager -o cat --since "@$RS" "_SYSTEMD_USER_UNIT=$FIXTURE-probe.service" "_UID=$CTR_UID" 2>/dev/null; }
n=0
while [ "$n" -lt 60 ] && ! probe_log | grep -q '^PROBE_READY'; do sleep 1; n=$((n+1)); done
if exec 3<>"/dev/tcp/127.0.0.1/$PROBE_PORT" 2>/dev/null; then
    reply=$(timeout 5 cat <&3 2>/dev/null); exec 3<&- 3>&-
    [ "$reply" = probe-ok ] && say_pass "published port forwards host -> container" || say_fail "published port: connected but got '$reply'"
else
    say_fail "published port: cannot connect to 127.0.0.1:$PROBE_PORT"
fi
n=0
while [ "$n" -lt 400 ] && ! probe_log | grep -q '^PROBE_DONE'; do sleep 1; n=$((n+1)); done
out=$(probe_log)
printf '%s\n' "$out" | grep -q '^PROBE_DONE' && say_pass "probes finished" || say_fail "probes did not finish"
[ "$(printf '%s\n' "$out" | sed -n 's/^PROBE_CONTROL //p')" = ok ] && say_pass "control: a default container starts" || say_fail "control: a default container did not start, every probe below is void"
case "$(printf '%s\n' "$out" | sed -n 's/^PROBE_BASELINE //p')" in *:container_t:*) say_pass "control: default container runs in container_t" ;; *) say_fail "control: default container is not in container_t" ;; esac
[ "$(printf '%s\n' "$out" | sed -n 's/^PROBE_LISTENER //p')" = true ] && say_pass "control: the listener outlived the probes" || say_fail "control: the listener died during the probes, port results are void"
want=$((2 * ($(echo "$LOCAL_ADDRS" | wc -w) + 3))); got=$(printf '%s\n' "$out" | grep -c '^PROBE_HOST')
[ "$got" = "$want" ] && say_pass "all $want address and port probes ran" || say_fail "ran $got of $want address and port probes"
[ "$(printf '%s\n' "$out" | sed -n 's/^PROBE_ROOTFS //p')" = ok ] && say_pass "control: the writable rootfs fixture was populated" || say_fail "control: the rootfs fixture is empty, its label results are void"
if [ "$(printf '%s\n' "$out" | sed -n 's/^PROBE_SUBUID_ID //p')" = 1000 ]; then
    [ "$(printf '%s\n' "$out" | sed -n 's/^PROBE_SUBUID //p')" = closed ] && say_pass "a mapped uid in the host network namespace cannot reach the gateway" || say_fail "a mapped uid in the host network namespace reached the gateway"
else
    say_fail "control: could not take a mapped uid, the mapped-uid probe is void"
fi
rules=$(nft list chain inet filter output 2>/dev/null)
case "$rules" in *224.0.0.0/4*ff00::/8*) say_pass "the output chain drops multicast and broadcast from the principal" ;; *) say_fail "the output chain has no multicast rule for the principal" ;; esac
opened=$(printf '%s\n' "$out" | grep '^PROBE_HOST open' || true)
[ -z "$opened" ] && say_pass "no local address reachable from a container ($(printf '%s\n' "$out" | grep -c '^PROBE_HOST') probes)" \
    || { say_fail "container reached the gateway:"; printf '%s\n' "$opened" | sed 's/^/    /'; }
case "$(printf '%s\n' "$out" | sed -n 's/^PROBE_EGRESS //p')" in
    ok) say_pass "container egress to $IOTGW_CTR_EGRESS_PROBE" ;;
    fail) say_fail "container egress to $IOTGW_CTR_EGRESS_PROBE" ;;
    *) say_skip "container egress" "set IOTGW_CTR_EGRESS_PROBE=host:port" ;;
esac
printf '%s\n' "$out" | sed -n 's/^PROBE_LABEL //p' | while IFS= read -r l; do printf '    %s\n' "$l"; done
bad=$(printf '%s\n' "$out" | sed -n 's/^PROBE_LABEL //p' | grep -v '=refused$' | grep -v ':container_t:' || true)
[ -z "$bad" ] && say_pass "no container started outside container_t" \
    || { say_fail "container outside container_t:"; printf '%s\n' "$bad" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
section "6. Store ownership and labels after the run"
bad=$(find "$STORE" \( ! -user "$CTR_USER" \) \( ! -uid +$((SUBID_BASE-1)) -o ! -uid -$((SUBID_BASE+SUBID_COUNT)) \) -print 2>/dev/null | head -5)
[ -z "$bad" ] && say_pass "every store file is owned by $CTR_USER or $SUBID_BASE..$((SUBID_BASE+SUBID_COUNT-1))" || say_fail "store files with other owners: $(echo "$bad" | tr '\n' ' ')"
if [ $SELINUX = 1 ] && [ -d "$STORE/storage/overlay" ]; then
    l=$(label_of "$STORE/storage/overlay")
    case "$l" in *:container_ro_file_t:*) say_pass "image layers label $l" ;; *) say_fail "image layers label $l (expected container_ro_file_t)" ;; esac
fi
evidence "store summary" sh -c "find '$STORE' -maxdepth 2 -printf '%u:%g %M %Z %p\n' 2>/dev/null | sort -u | head -20"

# ---------------------------------------------------------------------------
section "7. SELinux denials during the run"
if [ $SELINUX = 1 ] && [ $AUDIT_READABLE = 1 ]; then
    # The refused starts of section 5 are denials by design. Outside that window none is expected.
    rf=$(printf '%s\n' "$out" | sed -n 's/^PROBE_REFUSALS_FROM //p'); rt=$(printf '%s\n' "$out" | sed -n 's/^PROBE_REFUSALS_TO //p')
    say_info "$(avc_since "$rf" | awk -v b="$rt" -F'[(:]' '$2 + 0 <= b + 0' | wc -l) denial(s) from the refused starts, as expected"
    av=$(avc_since "$T0" "$rf" "$rt")
    if [ -z "$av" ]; then say_pass "0 AVC denials since the fixture started, outside the refused starts"
    else say_fail "$(echo "$av" | wc -l) AVC denial(s) during the run"; evidence "denials" sh -c "printf '%s\n' \"\$0\" | head -20" "$av"; fi
elif [ $SELINUX = 1 ]; then
    say_skip "AVC count" "audit.log not readable from $MY_CTX; run from the console (sysadm_t)"
else
    say_skip "AVC count" "SELinux not enabled"
fi

# ---------------------------------------------------------------------------
section "8. Cleanup"
if [ "$KEEP" = 1 ]; then
    say_skip "fixture removal" "IOTGW_CTR_KEEP=1; remove with: rm $QUADLET_DIR/$FIXTURE.container${LOAD_UNIT:+ $USER_UNIT_DIR/$LOAD_UNIT} $USER_UNIT_DIR/$FIXTURE-probe.service $USER_UNIT_DIR/default.target.wants/$FIXTURE-probe.service; systemctl restart user@$CTR_UID.service"
else
    cleanup_fixture
    n=0
    while [ "$n" -lt 30 ] && pgrep -u "$CTR_UID" -x sleep >/dev/null 2>&1; do sleep 1; n=$((n+1)); done
    if pgrep -u "$CTR_UID" -x sleep >/dev/null 2>&1; then say_fail "payload still running after the fixture was removed"
    else say_pass "fixture removed, payload gone, user@$CTR_UID.service restarted"; fi
    if systemctl is-active -q "user@$CTR_UID.service"; then say_pass "user@$CTR_UID.service active after cleanup"; else say_fail "user@$CTR_UID.service active after cleanup"; fi
fi

summary "principal: $CTR_USER uid=$CTR_UID subids=$SUBID_BASE+$SUBID_COUNT image=$IMAGE"
