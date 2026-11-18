#!/bin/sh
# iotgw-preinit: assemble the writable parts of the filesystem BEFORE PID 1.
#
# The boot path of every image tier, selected with
# init=/usr/sbin/iotgw-preinit on the signed slot-FIT kernel command line.
# Persistent state reaches the running system only through the explicit binds
# listed in docs/PERSISTENT_STATE.md; nothing on /data is ever an overlay
# layer. Order matters:
#   1. /proc, /sys, /run; a log in /run/iotgw.
#   2. /data: the GPT partition named "data" ON THE SAME DISK as the verity
#      root (read from the kernel's own partition metadata in /sys, no udev,
#      no filesystem label a plugged-in device could forge), bounded wait,
#      partition grown to the end of the disk, e2fsck -p with a time limit,
#      mount, filesystem grown online. Any failure except growth marks the
#      boot DEGRADED
#      (/run/iotgw/degraded=<reason>) and continues with the vendor
#      configuration only. Never halt, never reboot: both root slots share
#      /data, so the boot counters cannot fix a storage fault.
#   3. Load the SELinux policy, so that everything created from here on gets a
#      real label. PID 1 loads it a second time; that is systemd's behaviour,
#      not a mistake, and it reads the same read-only /etc/selinux.
#   4. Remove leftover persistent overlay uppers (/data/overlays) and OTA
#      reconciler state (/data/iotgw/overlay-reconcile).
#   5. Bind sources on /data: create the ones that are missing (/data/home is
#      seeded from the image's /home, one entry at a time), label them.
#   6. /home bound from /data/home (nodev,nosuid); without a usable /data it
#      falls back to a tmpfs overlay like /root.
#   7. Size-bounded tmpfs upper/work directories, labelled through
#      file_contexts.subs, then the /etc and /root overlays. Writes through
#      them live until the next reboot and never reach /data.
#   8. /etc/machine-id bound from /data when a valid persisted id exists.
#   9. exec /sbin/init.
# Binds under /var (journal, audit, pstore, bluetooth, thread) are systemd
# .mount units: /var/lib is a volatile-binds overlay that only exists
# after local-fs.target starts, so a bind made here would be hidden by it.
# Whatever goes wrong inside this script, systemd still starts: the EXIT trap
# execs it on any early exit, so a defect here is a degraded boot, not a
# kernel panic ("attempted to kill init") that would burn the boot counters.
# The script's own code is on the dm-verity root. Its only untrusted input is
# the content of /data, which it never executes and reads only as data: no
# path on /data is followed through a symlink, and a bind source that exists
# but is not a plain directory marks the boot degraded instead of being used.

# Exported: the kernel starts init without PATH, and a child such as timeout(1)
# then resolves its command through libc's fallback, which has no /usr/sbin.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RUNDIR=/run/iotgw
LOG=${RUNDIR}/preinit.log
OVL=${RUNDIR}/overlay
DATA_OPTS=noatime,nodiratime,commit=60
DATA_WAIT_TRIES=60          # x 0.5 s
FSCK_TIMEOUT=120            # seconds
UPPER_TMPFS_SIZE=64m
POLICY=0

log() {
    echo "[iotgw-preinit] $*" >> "$LOG" 2>/dev/null
    echo "<6>[iotgw-preinit] $*" > /dev/kmsg 2>/dev/null || echo "[iotgw-preinit] $*"
}
degraded() {
    mkdir -p "$RUNDIR" 2>/dev/null
    echo "$1" > "${RUNDIR}/degraded"
    log "DEGRADED: $1"
}
# restorecon runs in setfiles_t, which may not append to the log (a file on
# /run with no file context) but may write a pipe this kernel_t shell owns:
# stdin from /dev/null, output through a pipe into the log, exit status kept.
relabel() {
    { restorecon "$@" < /dev/null 2>&1; echo "$?" > "${RUNDIR}/.relabel-rc"; } |
        while IFS= read -r line; do echo "$line" >> "$LOG"; done
    return "$(cat "${RUNDIR}/.relabel-rc" 2>/dev/null || echo 1)"
}
# The SELinux context file ends in a NUL byte; bash warns when a command
# substitution drops it.
own_context() {
    tr -d '\000' < /proc/self/attr/current 2>/dev/null || echo unknown
}

# /data growth ----------------------------------------------------------------
# The image ships /data sized for the image; the card is usually larger. A
# partition can only be resized while it is not mounted, and pre-init is the
# one point where nothing has mounted /data yet, so the partition grows here,
# before e2fsck, and the filesystem grows online right after the mount. Both
# steps are decided from the current partition table and filesystem size: a
# boot with nothing to grow does nothing, and a boot interrupted half way
# finishes on the next one. A failure is logged and the boot continues on the
# smaller /data; it is never a reason for a degraded boot.
GROW_SLACK_SECTORS=2048     # less than 1 MiB to gain: leave it

# <disk> <partition number> -> "<disk sectors> <partition end sector>"
part_geometry() {
    parted -sm "$1" unit s print 2>/dev/null | awk -F: -v n="$2" '
        NR == 2 { sub(/s$/, "", $2); disk = $2 }
        $1 == n { sub(/s$/, "", $3); end = $3 }
        END { if (disk != "" && end != "") print disk, end; else exit 1 }'
}

grow_data_part() {
    g_disk=$1
    g_num=$2
    g_geo=$(part_geometry "$g_disk" "$g_num") || {
        log "grow: cannot read the partition table of $g_disk"
        return 1
    }
    # shellcheck disable=SC2086  # split "<disk> <end>" into $1 $2
    set -- $g_geo
    # The backup GPT occupies the last 33 sectors of the disk.
    if [ $(( $1 - 34 - $2 )) -le "$GROW_SLACK_SECTORS" ]; then
        return 0
    fi
    log "grow: partition $g_num ends at sector $2 of $1 on $g_disk"
    # A card larger than the image still has its backup GPT where the image
    # ended; move it to the end of the disk before the partition can extend.
    sgdisk -e "$g_disk" >> "$LOG" 2>&1 || { log "grow: sgdisk -e $g_disk failed"; return 1; }
    parted -s "$g_disk" resizepart "$g_num" 100% >> "$LOG" 2>&1 || {
        log "grow: parted resizepart $g_num failed"
        return 1
    }
    log "grow: partition $g_num now ends at the end of $g_disk"
}

# <ext4 device> <partition size in bytes>; the filesystem is mounted.
grow_data_fs() {
    g_dev=$1
    g_part_bytes=$2
    g_fs_bytes=$(dumpe2fs -h "$g_dev" 2>/dev/null | awk -F: '
        /^Block count:/ { c = $2 + 0 }
        /^Block size:/  { s = $2 + 0 }
        END { if (c && s) printf "%.0f\n", c * s; else exit 1 }') || {
        log "grow: cannot read the filesystem size of $g_dev"
        return 1
    }
    if [ $(( g_part_bytes - g_fs_bytes )) -le $(( GROW_SLACK_SECTORS * 512 )) ]; then
        return 0
    fi
    resize2fs "$g_dev" >> "$LOG" 2>&1 || { log "grow: resize2fs $g_dev failed"; return 1; }
    log "grow: filesystem on $g_dev grown to its partition"
}

# Last resort: never let PID 1 die. Reached only if something below exits the
# shell (a special-builtin failure, a signal we can catch, a stray `exit`).
hand_over() {
    trap - EXIT INT TERM HUP
    [ -e "${RUNDIR}/degraded" ] || degraded "preinit-aborted"
    # shellcheck disable=SC2093  # each exec is a fallback for the previous one failing
    exec /sbin/init "$@"
    # shellcheck disable=SC2093
    exec /lib/systemd/systemd "$@"
    exec /usr/lib/systemd/systemd "$@"
}
# shellcheck disable=SC2064  # $@ must be captured now, not at trap time
trap "hand_over $*" EXIT INT TERM HUP

mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys
mountpoint -q /run  || mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run
mkdir -p "$RUNDIR"
log "start ctx-before-load=$(own_context)"

# 2. /data -------------------------------------------------------------------
# The disk that carries the verity root: dm-mod.waitfor=/dev/<part> is on the
# signed command line. Its parent block device is the only place /data may be.
root_part=$(sed -n 's/.*dm-mod\.waitfor=\(\/dev\/[^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)
root_disk=""
if [ -n "$root_part" ] && [ -e "/sys/class/block/$(basename "$root_part")" ]; then
    root_disk=$(basename "$(readlink -f "/sys/class/block/$(basename "$root_part")/..")")
fi

find_data_part() {
    # GPT partition name "data" (PARTNAME in the kernel's uevent), same disk.
    for p in /sys/class/block/"${root_disk}"*; do
        [ -f "$p/partition" ] || continue
        if grep -qx 'PARTNAME=data' "$p/uevent" 2>/dev/null; then
            echo "/dev/$(basename "$p")"
            return 0
        fi
    done
    return 1
}

DEV=""
n=0
while [ "$n" -lt "$DATA_WAIT_TRIES" ]; do
    if [ -n "$root_disk" ]; then
        DEV=$(find_data_part) && [ -b "$DEV" ] && break
    else
        # No verity root on the command line (non-verity test boot): fall back
        # to the filesystem label and say so.
        DEV=$(findfs LABEL=data 2>/dev/null) && [ -n "$DEV" ] && break
    fi
    DEV=""
    sleep 0.5
    n=$((n + 1))
done

if [ -z "$DEV" ]; then
    degraded "data-device-not-found"
else
    if [ -n "$root_disk" ]; then
        log "data device: $DEV (partition named data on $root_disk, after $n waits)"
    else
        log "data device: $DEV (BY FILESYSTEM LABEL, no dm-mod.waitfor on the command line)"
    fi
    # Growth needs the disk the root is on; a label-fallback boot has none.
    if [ -n "$root_disk" ]; then
        grow_data_part "/dev/$root_disk" "$(cat "/sys/class/block/$(basename "$DEV")/partition")"
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout "$FSCK_TIMEOUT" e2fsck -p "$DEV" >> "$LOG" 2>&1
    else
        e2fsck -p "$DEV" >> "$LOG" 2>&1
    fi
    rc=$?
    # e2fsck: 0 clean, 1 corrected, 2 corrected (reboot advised for a root fs),
    # 4 and above: not repaired automatically. 124: timeout(1) expired.
    if [ "$rc" -eq 124 ]; then
        degraded "data-fsck-timeout-${FSCK_TIMEOUT}s"
    elif [ "$rc" -ge 4 ]; then
        degraded "data-fsck-failed-rc${rc}"
    else
        [ "$rc" -ne 0 ] && log "e2fsck repaired $DEV (rc=$rc)"
        if ! mount -t ext4 -o "$DATA_OPTS" "$DEV" /data >> "$LOG" 2>&1; then
            degraded "data-mount-failed"
        elif [ -n "$root_disk" ]; then
            grow_data_fs "$DEV" \
                "$(( $(cat "/sys/class/block/$(basename "$DEV")/size") * 512 ))"
        fi
    fi
fi

# 3. SELinux policy ------------------------------------------------------------
if [ -d /sys/fs/selinux ]; then
    mountpoint -q /sys/fs/selinux || mount -t selinuxfs selinuxfs /sys/fs/selinux 2>> "$LOG"
    if load_policy >> "$LOG" 2>&1; then
        POLICY=1
        log "policy loaded ctx-after-load=$(own_context)"
        # devtmpfs nodes created before the load carry root_t. This shell is
        # still kernel_t (chcon does not transition), which may relabel them;
        # restorecon would exec into setfiles_t first and be checked against
        # the stale labels of the descriptors it inherits.
        chcon -t null_device_t /dev/null 2>> "$LOG"
        chcon -t console_device_t /dev/console 2>> "$LOG"
        # Likewise $RUNDIR and what is already in it (this log, a degraded
        # marker) were created as tmpfs_t; files created from now on inherit
        # the directory's type. Same type iotgw.fc gives them.
        chcon -t var_run_t "$RUNDIR" "$RUNDIR"/* 2>> "$LOG"
    else
        degraded "policy-load-failed"
    fi
fi

# 4. Leftover persistent overlays ------------------------------------------
# Older slots kept persistent /etc, /home and /root overlay uppers on /data and
# an OTA reconciler state that converged them. Nothing here mounts or reads
# them, and a stale upper must not survive to be mounted by anything. Runs on
# every boot where they exist, so a round trip through an older slot (which
# recreates them) leaves nothing behind. rm never
# follows a symlink as the operand or inside the tree; a symlinked ancestor
# below /data would still redirect it, so every ancestor is checked first.
data_ok() { mountpoint -q /data; }
# True when nothing between /data and $1 is a symlink or a non-directory.
# A missing ancestor is fine: then $1 does not exist either.
ancestors_real() {
    p=${1%/*}
    while [ "$p" != /data ] && [ -n "$p" ]; do
        [ -L "$p" ] && return 1
        [ -e "$p" ] || return 0
        [ -d "$p" ] || return 1
        p=${p%/*}
    done
    return 0
}
if data_ok; then
    for old in /data/overlays /data/iotgw/overlay-reconcile; do
        if ! ancestors_real "$old"; then
            degraded "retired-path-ancestor-not-a-directory:$old"
        elif [ -L "$old" ]; then
            rm -f "$old" && log "removed retired symlink $old"
        elif [ -d "$old" ]; then
            if rm -rf "$old" >> "$LOG" 2>&1; then
                log "removed retired $old"
            else
                log "WARN: could not remove retired $old"
            fi
        fi
    done
fi

# 5. Bind sources on /data ------------------------------------------------------
# A bind source that is missing is created; one that exists as anything but a
# real directory (symlink, file, device) is never used: the boot is degraded
# and the bind falls back to the volatile path. Labels come from the
# file_contexts.subs aliases (/data/<x> -> the path it is bound on).
bind_source_ok() {
    # $1 = path on /data. Succeeds when it is (now) a real directory.
    if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
        degraded "bind-source-not-a-directory:$1"
        return 1
    fi
    if [ ! -d "$1" ]; then
        mkdir -m 0755 "$1" >> "$LOG" 2>&1 || { degraded "bind-source-mkdir-failed:$1"; return 1; }
        log "created bind source $1"
    fi
    [ "$POLICY" = 1 ] && { relabel -F "$1" || log "WARN: restorecon $1 failed"; }
    return 0
}

# A home copied in by an earlier image keeps that image's numeric owner, and
# UIDs are allocated per image: after a switch between image variants a home
# can belong to another account (devel was 1000 on the dev image, which is
# weston on the desktop image), and sshd then refuses its authorized_keys.
# Re-own a home whose top-level owner is not its user's UID in this image's
# /etc/passwd. Only homes at /home/<user> of an existing user; symlinks are
# neither followed nor re-owned (chown -h, and -R does not traverse them).
reown_homes() {
    while IFS=: read -r user _pw uid gid _gecos home _shell; do
        [ "$home" = "/home/$user" ] || continue
        d="/data/home/$user"
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        cur=$(stat -c %u "$d" 2>/dev/null) || continue
        [ "$cur" = "$uid" ] && continue
        if chown -R -h "$uid:$gid" "$d" >> "$LOG" 2>&1; then
            log "re-owned /data/home/$user from uid $cur to $uid:$gid"
        else
            log "WARN: re-owning /data/home/$user failed"
        fi
    done < /etc/passwd
}

HOME_BIND=0
if data_ok; then
    # /data/ota-tmp: local bundle staging for `rauc install <file>`. Its type
    # (file_contexts.local) is RAUC's own, and a copied bundle inherits the
    # directory's type, so it must exist and be labelled before anything is
    # copied in; created by a shell later it would carry /data's var_lib_t. Not
    # a bind source: anything odd here is logged, never a reason to degrade.
    if [ ! -e /data/ota-tmp ] && [ ! -L /data/ota-tmp ]; then
        mkdir -m 0750 /data/ota-tmp >> "$LOG" 2>&1 && log "created /data/ota-tmp"
    fi
    # The OTA operator account (prod) stages bundles here: group-writable for
    # it, by name, so the ownership follows the account's fixed ID.
    if [ -d /data/ota-tmp ] && [ ! -L /data/ota-tmp ] && getent group iotgw-ops >/dev/null 2>&1; then
        chgrp iotgw-ops /data/ota-tmp >> "$LOG" 2>&1 && chmod 2770 /data/ota-tmp >> "$LOG" 2>&1
    fi
    if [ -d /data/ota-tmp ] && [ ! -L /data/ota-tmp ] && [ "$POLICY" = 1 ]; then
        relabel -R -F /data/ota-tmp || log "WARN: restorecon /data/ota-tmp failed"
    fi

    # /data/home: the image's /home entries (user homes created at build time,
    # shipped dotfiles and keys) are copied in once, each entry only while it
    # is absent on /data. A later image's change to a file inside an existing
    # home does not reach /data; a new user's home does.
    if bind_source_ok /data/home; then
        HOME_BIND=1
        for src in /home/* /home/.[!.]*; do
            [ -e "$src" ] || [ -L "$src" ] || continue
            name=$(basename "$src")
            dst="/data/home/$name"
            [ -e "$dst" ] || [ -L "$dst" ] && continue
            rm -rf "/data/home/.seed.$name" 2>/dev/null
            if cp -a "$src" "/data/home/.seed.$name" >> "$LOG" 2>&1 \
               && mv "/data/home/.seed.$name" "$dst" >> "$LOG" 2>&1; then
                [ "$POLICY" = 1 ] && { relabel -R -F "$dst" || log "WARN: restorecon $dst failed"; }
                log "seeded /data/home/$name from the image"
            else
                log "WARN: seeding /data/home/$name failed"
            fi
        done
        reown_homes
    fi
fi

# 6. /home ---------------------------------------------------------------------
# Bound before the overlays: if the bind fails, /home falls back to the same
# tmpfs overlay as /root instead of staying read-only.
if [ "$HOME_BIND" = 1 ]; then
    if mount --bind /data/home /home >> "$LOG" 2>&1; then
        mount -o remount,bind,nodev,nosuid /home >> "$LOG" 2>&1 \
            || log "WARN: /home remount nodev,nosuid failed"
        log "/home bound from /data/home"
    else
        degraded "home-bind-failed"
        HOME_BIND=0
    fi
fi

# 7. Ephemeral overlays --------------------------------------------------------
# /etc and /root always; /home only when it cannot be bound from /data.
OVL_DIRS="etc root"
[ "$HOME_BIND" = 1 ] || OVL_DIRS="$OVL_DIRS home"
mkdir -p "$OVL"
if mount -t tmpfs -o "mode=0755,nodev,nosuid,size=${UPPER_TMPFS_SIZE}" tmpfs "$OVL" >> "$LOG" 2>&1; then
    for d in $OVL_DIRS; do
        mkdir -p "$OVL/$d/upper" "$OVL/$d/work"
    done
    # The upper root's label becomes the merged directory's label: give each
    # one its /etc, /root, /home type before anything is mounted on top.
    if [ "$POLICY" = 1 ]; then
        relabel -R -F "$OVL" || log "WARN: restorecon of $OVL failed"
    fi
    for d in $OVL_DIRS; do
        opts="lowerdir=/$d,upperdir=$OVL/$d/upper,workdir=$OVL/$d/work"
        [ "$d" = home ] && opts="$opts,nodev,nosuid"
        if ! mount -t overlay overlay -o "$opts" "/$d" >> "$LOG" 2>&1; then
            degraded "overlay-$d-failed"
        fi
    done
else
    degraded "overlay-tmpfs-failed"
fi

# 8. machine-id ----------------------------------------------------------------
MID=/data/machine-id
if data_ok && [ -f "$MID" ] && [ ! -L "$MID" ] \
   && grep -qE '^[0-9a-f]{32}$' "$MID" 2>/dev/null; then
    if mount --bind "$MID" /etc/machine-id >> "$LOG" 2>&1; then
        mount -o remount,bind,ro /etc/machine-id >> "$LOG" 2>&1 || true
        log "machine-id bound from /data"
    else
        log "WARN: machine-id bind failed; iotgw-machine-id.service will retry"
    fi
fi

if [ -e "${RUNDIR}/degraded" ]; then
    log "handing over to init DEGRADED ($(cat "${RUNDIR}/degraded"))"
else
    log "assembly complete, handing over to init"
fi
trap - EXIT INT TERM HUP
# shellcheck disable=SC2093  # each exec is a fallback for the previous one failing
exec /sbin/init "$@"
# exec failed (should be impossible on a verity root): try systemd directly.
# shellcheck disable=SC2093
exec /lib/systemd/systemd "$@"
exec /usr/lib/systemd/systemd "$@"
