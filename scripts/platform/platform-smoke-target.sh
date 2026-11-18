#!/bin/bash
# Boot-platform smoke for the IoT Gateway distro (iotgw).
#
# Asserts what the kernel configuration and the pre-init stage promise on a
# running device, in whichever mode the device booted:
#   - kernel/BSP: built-in symbols the boot depends on, SD card numbering,
#     verity root, regulators, thermal, tmpfs, CMA, RP1 Ethernet, V3D, watchdog
#   - hardening sysctls
#   - pre-init: /data mounted and grown to the end of the card (healthy), or a
#     recovery-mode boot (/run/iotgw/degraded) with the /data-dependent units
#     skipped instead of failed
#   - SSH host keys: served from /run/sshd-keys, persisted on /data when it is
#     mounted, RSA at least 4096 bits
#   - GPU userspace: Mesa V3D driver where GL is installed, no GL in prod
#
# Usage:
#   sudo ./platform-smoke-target.sh
#   cat scripts/lib/target-check.sh scripts/platform/platform-smoke-target.sh | ssh <gw> 'bash -s'
#   scripts/run-target-checks.sh <gw> platform-smoke
#
# Run it over the serial console as well when testing recovery mode: SSH keys
# in that mode are per boot, so the host key a client sees changes.

set -u

# Reporting helpers: streamed ahead of this script by run-target-checks.sh,
# otherwise sourced from the repo layout.
if ! command -v say_pass >/dev/null 2>&1; then
    # shellcheck source=../lib/target-check.sh
    . "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../lib/target-check.sh" || exit 2
fi

DEGRADED_MARK=/run/iotgw/degraded
PREINIT_LOG=/run/iotgw/preinit.log
RSA_BITS=4096
GROW_SLACK_SECTORS=2048     # pre-init leaves less than this ungrown

degraded=0
[ -e "$DEGRADED_MARK" ] && degraded=1

# Unit loaded from a unit file on this image (not "not-found").
unit_present() {
    [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" = "loaded" ]
}

# ---------------------------------------------------------------------------
section "Boot mode"
if [ "$degraded" -eq 1 ]; then
    say_pass "recovery mode: $(cat "$DEGRADED_MARK" 2>/dev/null)"
    if mountpoint -q /data; then
        say_fail "/data is mounted although the boot is marked degraded"
    else
        say_pass "/data is not mounted"
    fi
else
    say_pass "normal boot (no $DEGRADED_MARK)"
    if mountpoint -q /data; then
        say_pass "/data mounted ($(findmnt -no SOURCE /data))"
    else
        say_fail "/data not mounted and the boot is not marked degraded"
    fi
fi
if [ -r "$PREINIT_LOG" ]; then
    say_pass "pre-init log present ($PREINIT_LOG)"
else
    say_fail "pre-init log missing ($PREINIT_LOG) — pre-init did not run"
fi
# bthelper (pi-bluetooth) reads device-tree strings through a command
# substitution and always trips the warning; it is not ours.
nb=$(journalctl -b --no-pager 2>/dev/null | grep 'ignored null byte' \
    | grep -vc ' bthelper\[')
if [ "${nb:-0}" -eq 0 ]; then
    say_pass "no 'ignored null byte' warnings this boot"
else
    say_fail "$nb 'ignored null byte' warning(s) this boot"
fi

# ---------------------------------------------------------------------------
section "Kernel configuration"
if [ -r /proc/config.gz ]; then
    for sym in BCM2712_MIP PCIE_BRCMSTB MMC_SDHCI_BRCMSTB REGULATOR TMPFS \
               THERMAL CMA DRM_V3D BCM2835_WDT; do
        v=$(zcat /proc/config.gz | grep -E "^CONFIG_${sym}=" | cut -d= -f2)
        if [ "$v" = "y" ]; then
            say_pass "CONFIG_${sym}=y"
        else
            say_fail "CONFIG_${sym}=${v:-unset} (built-in expected)"
        fi
    done
else
    say_skip "kernel symbols" "/proc/config.gz absent (IKCONFIG off)"
fi

# ---------------------------------------------------------------------------
section "Storage and memory"
if [ "$(cat /sys/block/mmcblk0/device/type 2>/dev/null)" = "SD" ]; then
    say_pass "mmcblk0 is the SD card"
else
    say_fail "mmcblk0 is not the SD card (aliases missing from the DTB?)"
fi
root_src=$(findmnt -no SOURCE / 2>/dev/null)
case "$root_src" in
    /dev/dm-*|/dev/mapper/*) say_pass "root on a device-mapper target ($root_src)" ;;
    *)                       say_fail "root not on dm-verity ($root_src)" ;;
esac
for m in /run /dev/shm; do
    fs=$(awk -v m="$m" '$5 == m { print $9; exit }' /proc/1/mountinfo)
    if [ "$fs" = "tmpfs" ]; then say_pass "$m is tmpfs"
    else say_fail "$m is ${fs:-not mounted}, tmpfs expected"; fi
done
cma=$(awk '/^CmaTotal:/ { print $2 }' /proc/meminfo)
if [ "${cma:-0}" -gt 0 ]; then say_pass "CMA reserved (${cma} kB)"
else say_fail "no CMA (CmaTotal ${cma:-absent})"; fi

# ---------------------------------------------------------------------------
section "Power, thermal, watchdog"
nreg=$(ls /sys/class/regulator 2>/dev/null | wc -l)
if [ "$nreg" -gt 0 ]; then say_pass "$nreg regulator(s) registered"
else say_fail "no regulators registered"; fi
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    say_pass "thermal_zone0 $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )) C"
else
    say_fail "thermal_zone0 missing"
fi
if [ -e /dev/watchdog0 ]; then say_pass "/dev/watchdog0 present"
else say_fail "/dev/watchdog0 missing"; fi
wd=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)
case "$wd" in
    ""|0|infinity) say_fail "systemd runtime watchdog not armed (${wd:-unknown})" ;;
    *)             say_pass "systemd runtime watchdog ${wd}" ;;
esac

# ---------------------------------------------------------------------------
section "RP1 Ethernet"
# The RP1 south bridge sits behind PCIe and needs the BCM2712 MSI controller
# before the deferred-probe timeout; a late userspace start must not lose eth0.
if [ -e /sys/class/net/eth0 ]; then
    drv=$(basename "$(readlink -f /sys/class/net/eth0/device/driver 2>/dev/null)")
    say_pass "eth0 present (driver ${drv:-unknown})"
else
    say_fail "eth0 missing"
fi
msix=$(dmesg 2>/dev/null | grep -c 'Failed to allocate MSI-X')
if [ "${msix:-0}" -eq 0 ]; then say_pass "no RP1 MSI-X allocation failure"
else say_fail "RP1 MSI-X allocation failed ($msix line(s) in dmesg)"; fi
carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null)
if [ "$carrier" = "1" ]; then say_pass "eth0 carrier up"
else say_skip "eth0 carrier" "no link (cable?)"; fi

# ---------------------------------------------------------------------------
section "Hardening sysctls"
for kv in vm.mmap_rnd_bits=33 fs.suid_dumpable=0; do
    k=${kv%%=*}; want=${kv#*=}
    got=$(sysctl -n "$k" 2>/dev/null)
    if [ "$got" = "$want" ]; then say_pass "$k = $got"
    else say_fail "$k = ${got:-unreadable} (want $want)"; fi
done

# ---------------------------------------------------------------------------
section "/data partition growth"
if [ "$degraded" -eq 1 ]; then
    say_skip "/data growth" "recovery mode: pre-init did not touch /data"
elif ! mountpoint -q /data; then
    say_skip "/data growth" "/data not mounted"
else
    dev=$(findmnt -no SOURCE /data)
    part=$(basename "$(readlink -f "$dev")")
    disk=$(basename "$(readlink -f "/sys/class/block/$part/..")")
    disk_sz=$(cat "/sys/block/$disk/size" 2>/dev/null)
    p_start=$(cat "/sys/class/block/$part/start" 2>/dev/null)
    p_size=$(cat "/sys/class/block/$part/size" 2>/dev/null)
    if [ -z "$disk_sz" ] || [ -z "$p_start" ] || [ -z "$p_size" ]; then
        say_fail "cannot read the geometry of $part on $disk"
    else
        # The backup GPT takes the last 34 sectors of the disk.
        left=$(( disk_sz - 34 - (p_start + p_size - 1) ))
        if [ "$left" -le "$GROW_SLACK_SECTORS" ]; then
            say_pass "$part reaches the end of $disk ($left sector(s) left)"
        else
            say_fail "$part leaves $left sectors unallocated at the end of $disk"
        fi
        fs_bytes=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '
            /^Block count:/ { c = $2 } /^Block size:/ { s = $2 }
            END { if (c && s) printf "%d", c * s }')
        p_bytes=$(( p_size * 512 ))
        if [ -z "$fs_bytes" ]; then
            say_fail "cannot read the filesystem size on $dev"
        elif [ $(( p_bytes - fs_bytes )) -le $(( GROW_SLACK_SECTORS * 512 )) ]; then
            say_pass "filesystem on $dev fills its partition"
        else
            say_fail "filesystem on $dev is $(( (p_bytes - fs_bytes) / 1048576 )) MiB smaller than its partition"
        fi
    fi
    if unit_present rauc-grow-data-partition.service; then
        say_fail "retired rauc-grow-data-partition.service still installed"
    else
        say_pass "no separate grow service (pre-init owns growth)"
    fi
fi

# ---------------------------------------------------------------------------
section "SSH host keys"
if systemctl is-active --quiet sshd.service; then say_pass "sshd.service active"
else say_fail "sshd.service not active"; fi
# A unit that is not installed also reports Result=success.
if unit_present iotgw-sshd-keys.service \
   && [ "$(systemctl show -p Result --value iotgw-sshd-keys.service)" = "success" ]; then
    say_pass "iotgw-sshd-keys.service succeeded"
else
    say_fail "iotgw-sshd-keys.service did not succeed"
fi
for t in rsa ecdsa ed25519; do
    k=/run/sshd-keys/ssh_host_${t}_key
    if [ ! -f "$k" ] || [ -L "$k" ]; then
        say_fail "$k missing"
        continue
    fi
    mode=$(stat -c %a "$k")
    [ "$mode" = "600" ] || say_fail "$k mode $mode (600 expected)"
    if [ "$t" = rsa ]; then
        bits=$(ssh-keygen -l -f "$k.pub" 2>/dev/null | cut -d' ' -f1)
        if [ "${bits:-0}" -ge "$RSA_BITS" ]; then say_pass "RSA host key ${bits} bits"
        else say_fail "RSA host key ${bits:-?} bits (< $RSA_BITS)"; fi
    fi
    if [ "$degraded" -eq 1 ] || ! mountpoint -q /data; then
        say_pass "$t key present (per-boot key, /data not mounted)"
    elif cmp -s "$k.pub" "/data/ssh/ssh_host_${t}_key.pub"; then
        say_pass "$t key persisted on /data"
    else
        say_fail "$t key differs from /data/ssh (not persisted)"
    fi
done
# Read the configuration file instead of sshd -T, which loads the keys and the
# SSH login domain (staff_t) may not read them. On a read-only root sshd runs
# with -f sshd_config_readonly; plain sshd_config is then unused.
sshd_cfg=/etc/ssh/sshd_config
[ -f /etc/ssh/sshd_config_readonly ] && sshd_cfg=/etc/ssh/sshd_config_readonly
cfg=$(awk 'tolower($1) == "hostkey" { print $2 }' "$sshd_cfg" 2>/dev/null)
if [ -z "$cfg" ]; then
    say_fail "no HostKey lines in $sshd_cfg"
elif printf '%s\n' "$cfg" | grep -qv '^/run/sshd-keys/'; then
    say_fail "$sshd_cfg HostKey paths outside /run/sshd-keys: $(echo $cfg)"
else
    say_pass "sshd serves its host keys from /run/sshd-keys"
fi

# ---------------------------------------------------------------------------
section "Units that depend on /data"
# Recovery mode skips these by condition; they must never end up failed.
for u in ota-certs-provision.service edge-healthd.service bluetooth.service; do
    unit_present "$u" || { say_skip "$u" "not on this image"; continue; }
    st=$(systemctl show -p ActiveState --value "$u")
    if [ "$st" = "failed" ]; then
        say_fail "$u failed"
    else
        say_pass "$u $st"
    fi
done
if [ "$degraded" -eq 1 ]; then
    u=ota-certs-provision.service
    if unit_present "$u"; then
        cr=$(systemctl show -p ConditionResult --value "$u")
        ts=$(systemctl show -p ConditionTimestampMonotonic --value "$u")
        if [ "${ts:-0}" = "0" ]; then
            say_pass "$u not started this boot"
        elif [ "$cr" = "no" ]; then
            say_pass "$u skipped by condition"
        else
            say_fail "$u ran in recovery mode (ConditionResult=$cr)"
        fi
    fi
    if systemctl is-active --quiet edge-healthd.service; then
        say_pass "edge-healthd runs in recovery mode"
    else
        say_fail "edge-healthd not running in recovery mode"
    fi
fi
st=$(stat -c '%a %U' /var/lib/bluetooth 2>/dev/null)
case "$st" in
    "700 root") say_pass "/var/lib/bluetooth 0700 root" ;;
    "")         say_skip "/var/lib/bluetooth" "absent" ;;
    *)          say_fail "/var/lib/bluetooth is '$st' (0700 root expected)" ;;
esac

# ---------------------------------------------------------------------------
section "GPU"
if [ -e /dev/dri/renderD128 ]; then say_pass "/dev/dri/renderD128 present"
else say_fail "/dev/dri/renderD128 missing (V3D not bound)"; fi
gl=$(ls /usr/lib/libEGL.so.1 /usr/lib/libgbm.so.1 2>/dev/null)
if [ -n "$gl" ]; then
    # Mesa 24.3+ links every Gallium driver into libgallium-<ver>.so and
    # drops the per-driver /usr/lib/dri/*_dri.so files.
    if ls /usr/lib/dri/*v3d* >/dev/null 2>&1 \
        || grep -aqs 'v3d_nonmsaa_texture_size_limit' /usr/lib/libgallium-*.so; then
        say_pass "Mesa V3D driver installed"
    else
        say_fail "GL libraries installed without the V3D driver"
    fi
else
    say_pass "no GL userspace on this image (prod)"
fi

# ---------------------------------------------------------------------------
summary "mode: $([ "$degraded" -eq 1 ] && echo recovery || echo normal)"
