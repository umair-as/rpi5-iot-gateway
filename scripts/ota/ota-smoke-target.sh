#!/bin/bash
# Post-OTA / BSP smoke for the IoT Gateway distro (iotgw).
#
# Confirms RAUC slot accounting, U-Boot env steady-state, BSP feature
# presence (RTC, RP1 SPI0, TPM, VCIO mailbox, ramoops/pstore), systemd
# unit health, image identity, and dmesg sanity. Exits non-zero on any
# failure; prints a per-section summary suitable for both manual review
# and CI consumption.
#
# Usage:
#   # On target directly:
#   sudo ./ota-smoke-target.sh
#
#   # From host over SSH (no copy needed):
#   ssh <gw> 'sudo bash -s' < scripts/ota/ota-smoke-target.sh
#
# Pairs with:
#   scripts/ota/ota-certs-sync.sh    — operator workflow to provision OTA certs
#   scripts/ota/ota-bench-target.sh  — OTA throughput / install-time benchmark

set -u
PASS=0
FAIL=0
SKIP=0

say_pass() { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
say_fail() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
say_skip() { printf '  \e[33mSKIP\e[0m %s — %s\n' "$1" "${2:-}"; SKIP=$((SKIP+1)); }
section()  { printf '\n== %s ==\n' "$1"; }

# Run a command, pass if exit 0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then say_pass "$name"; else say_fail "$name"; fi
}

# Run a command, capture stdout, pass if matches regex
check_match() {
    local name="$1" regex="$2"; shift 2
    local out
    out=$("$@" 2>/dev/null) || { say_fail "$name (command failed)"; return; }
    if printf '%s' "$out" | grep -qE "$regex"; then say_pass "$name"
    else say_fail "$name (no match for '$regex')"; fi
}

# ---------------------------------------------------------------------------
section "RAUC slot accounting"
# rauc status should show the slot booted and its state. After a successful OTA
# the booted slot is "good" and the other slot is "good" or "inactive".
if command -v rauc >/dev/null 2>&1; then
    # mktemp, not a fixed /tmp path: as root a predictable name can follow a
    # pre-planted symlink (truncate an arbitrary file) or source attacker-seeded
    # shell. mktemp creates a fresh, unpredictable, private file.
    _rauc_env=$(mktemp)
    rauc status --output-format=shell > "$_rauc_env" 2>/dev/null
    # Sourcing a runtime rauc-status dump — nothing static for shellcheck to follow.
    # shellcheck source=/dev/null
    . "$_rauc_env" 2>/dev/null || true
    rm -f "$_rauc_env"
    rauc status 2>&1 | sed 's/^/    /' | head -25

    # Find booted slot by scanning RAUC_SLOT_STATE_N (actual shell-format names
    # rauc emits — RAUC_BOOT_PRIMARY also helps but doesn't carry the index).
    booted_idx=
    for i in ${RAUC_SLOTS:-}; do
        v="RAUC_SLOT_STATE_$i"; state=${!v:-}
        if [ "$state" = "booted" ]; then booted_idx=$i; break; fi
    done
    if [ -n "$booted_idx" ]; then
        v="RAUC_SLOT_BOOTNAME_$booted_idx";    booted_bn=${!v:-}
        v="RAUC_SLOT_BOOT_STATUS_$booted_idx"; booted_status=${!v:-}
        say_pass "booted slot: ${RAUC_BOOT_PRIMARY:-?} (bootname=$booted_bn)"
        if [ "$booted_status" = "good" ]; then
            say_pass "booted slot boot_status: good"
        else
            say_fail "booted slot boot_status: $booted_status"
        fi
    else
        say_fail "no slot in 'booted' state from rauc shell vars"
    fi
else
    say_skip "rauc binary" "not installed"
fi

# ---------------------------------------------------------------------------
section "U-Boot environment state"
if command -v fw_printenv >/dev/null 2>&1; then
    for var in BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT bootcount upgrade_available rauc_slot; do
        v=$(fw_printenv -n "$var" 2>/dev/null)
        printf '    %-20s = %s\n' "$var" "${v:-(unset)}"
    done
    # Project convention: iotgw_rauc_select uses BOOT_<slot>_LEFT for retries, NOT
    # bootcount. rauc-mark-good restores BOOT_<booted>_LEFT to 3 on confirmed boot.
    # upgrade_available is only set during an in-flight OTA; unset is the steady state.
    rauc_slot=$(fw_printenv -n rauc_slot 2>/dev/null)
    case "$rauc_slot" in
        A) left=$(fw_printenv -n BOOT_A_LEFT 2>/dev/null) ;;
        B) left=$(fw_printenv -n BOOT_B_LEFT 2>/dev/null) ;;
        *) left= ;;
    esac
    if [ "${left:-x}" = "3" ]; then
        say_pass "BOOT_${rauc_slot}_LEFT=3 (retries restored — slot confirmed good)"
    else
        say_fail "BOOT_${rauc_slot}_LEFT=$left (expected 3 after rauc-mark-good)"
    fi
    # upgrade_available: unset = OK (steady state); non-zero = pending confirm.
    ua=$(fw_printenv -n upgrade_available 2>/dev/null)
    if [ -z "$ua" ] || [ "$ua" = "0" ]; then
        say_pass "upgrade_available=${ua:-(unset)} (no OTA pending confirm)"
    else
        say_fail "upgrade_available=$ua (OTA still pending boot confirmation)"
    fi
    if systemctl is-active --quiet rauc-mark-good.service 2>/dev/null \
       || [ "$(systemctl show -p Result --value rauc-mark-good.service 2>/dev/null)" = "success" ]; then
        say_pass "rauc-mark-good.service ran successfully"
    else
        say_fail "rauc-mark-good.service did not run successfully"
    fi
else
    say_skip "fw_printenv" "not installed"
fi

# ---------------------------------------------------------------------------
section "BSP feature presence"

# RTC (patches linux/files/0001 driver + 0002 DT node)
if [ -e /dev/rtc0 ]; then
    say_pass "/dev/rtc0 present"
    if hwclock --rtc=/dev/rtc0 -r >/dev/null 2>&1; then
        say_pass "RTC readable via hwclock"
    else
        say_fail "RTC present but hwclock read failed"
    fi
else
    say_fail "/dev/rtc0 missing — RTC driver or DT node not loaded"
fi
# Authoritative driver name via sysfs (dmesg ring buffer may have rolled).
if [ -r /sys/class/rtc/rtc0/name ]; then
    rtc_name=$(cat /sys/class/rtc/rtc0/name)
    if printf '%s' "$rtc_name" | grep -q rpi; then
        say_pass "RTC driver: $rtc_name"
    else
        say_fail "RTC driver does not match 'rpi': $rtc_name"
    fi
else
    say_fail "/sys/class/rtc/rtc0/name unreadable"
fi

# RP1 SPI0 controller (patch linux/files/0003)
if ls /sys/class/spi_master/spi* >/dev/null 2>&1; then
    n=$(ls /sys/class/spi_master/ | wc -l)
    say_pass "$n SPI master(s) registered"
else
    say_fail "no SPI masters under /sys/class/spi_master/ — RP1 SPI0 patch not applied?"
fi

# TPM on RP1 SPI0 CS1 (patch linux/files/0004 + iotgw-common.inc gate)
if [ -e /dev/tpm0 ]; then
    say_pass "/dev/tpm0 present"
    if command -v tpm2_getcap >/dev/null 2>&1; then
        check "tpm2_getcap properties-fixed responds" tpm2_getcap properties-fixed
    fi
else
    say_skip "/dev/tpm0" "absent — IOTGW_ENABLE_TPM_SLB9672 likely disabled in this build"
fi

# VCIO mailbox userspace driver (patch linux/files/0006)
if [ -e /dev/vcio ]; then
    say_pass "/dev/vcio present"
else
    say_skip "/dev/vcio" "absent — IOTGW_ENABLE_VCIO disabled or driver gated off"
fi

# ramoops / pstore (patch linux/files/0007 + IOTGW_ENABLE_PSTORE_PERSIST)
if mountpoint -q /sys/fs/pstore; then
    say_pass "/sys/fs/pstore mounted"
    # Survives across the OTA reboot: previous boot's pstore should have been
    # archived by systemd-pstore to /var/lib/systemd/pstore (bind-mounted to /data).
    if [ -d /var/lib/systemd/pstore ]; then
        say_pass "pstore archive directory exists"
    else
        say_skip "pstore archive dir" "/var/lib/systemd/pstore not present"
    fi
else
    say_fail "/sys/fs/pstore not mounted — ramoops reserved-memory patch not applied?"
fi

# ---------------------------------------------------------------------------
section "Systemd unit health"
failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null)
if [ -z "$failed" ]; then
    say_pass "no failed units"
else
    say_fail "failed units present:"
    printf '%s\n' "$failed" | sed 's/^/      /'
    # Hint for the known "cert source missing" condition — operator workflow is
    # `scripts/ota/ota-certs-sync.sh` from the host (see docs/OTA_UPDATE.md).
    if printf '%s' "$failed" | grep -q 'ota-certs-provision'; then
        printf '      hint: run scripts/ota/ota-certs-sync.sh on the host to provision certs\n'
    fi
fi

state=$(systemctl is-system-running 2>/dev/null)
case "$state" in
    running)        say_pass "system state: running" ;;
    degraded)       say_fail "system state: degraded (see 'systemctl --failed')" ;;
    initializing|starting) say_skip "system state" "still $state — re-run in a moment" ;;
    *)              say_fail "system state: $state" ;;
esac

# Services we care about (only check those expected on this image)
for svc in iotgw-provision.service rauc.service iotgw-nftables.service; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1 && systemctl cat "$svc" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            say_pass "$svc present and active/enabled"
        else
            state=$(systemctl is-active "$svc" 2>/dev/null)
            say_fail "$svc present but state=$state"
        fi
    else
        say_skip "$svc" "not present on this image"
    fi
done

# SSH is socket-activated and hardened in this layer (sshd.socket).
# Accept any of the conventional unit names being active or enabled.
ssh_unit=
for svc in sshd.socket sshd.service openssh-sshd.service ssh.service; do
    systemctl list-unit-files "$svc" >/dev/null 2>&1 || continue
    if systemctl is-active --quiet "$svc" 2>/dev/null \
       || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        ssh_unit=$svc; break
    fi
done
if [ -n "$ssh_unit" ]; then
    say_pass "SSH entry point active/enabled: $ssh_unit"
else
    say_fail "no SSH unit (sshd.socket / sshd.service / openssh-sshd.service / ssh.service) active or enabled"
fi

# ---------------------------------------------------------------------------
section "Network stack (systemd-networkd)"
# This distro uses systemd-networkd + systemd-resolved (NetworkManager was
# removed). Assert the stack is the expected one, not just that nothing failed.
if command -v NetworkManager >/dev/null 2>&1; then
    say_fail "NetworkManager binary present (expected removed after networkd migration)"
else
    say_pass "NetworkManager absent"
fi

for svc in systemd-networkd.service systemd-resolved.service; do
    if systemctl is-active --quiet "$svc"; then
        say_pass "$svc active"
    else
        say_fail "$svc not active (state=$(systemctl is-active "$svc" 2>/dev/null))"
    fi
done

# wpa_supplicant is per-interface (wpa_supplicant@wlan0); only assert when the
# radio exists on this board.
if [ -e /sys/class/net/wlan0 ]; then
    if systemctl is-active --quiet wpa_supplicant@wlan0.service; then
        say_pass "wpa_supplicant@wlan0 active"
    else
        say_fail "wlan0 present but wpa_supplicant@wlan0 not active"
    fi
else
    say_skip "wpa_supplicant@wlan0" "no wlan0 interface on this board"
fi

# Connectivity: at least one non-loopback interface holds a global-scope IPv4
# (br0 wired uplink and/or wlan0). networkd assigns these once a link is up.
globs=$(ip -o -4 addr show scope global up 2>/dev/null | awk '{print $2"="$4}')
if [ -n "$globs" ]; then
    say_pass "global IPv4 up: $(printf '%s' "$globs" | tr '\n' ' ')"
else
    say_fail "no global-scope IPv4 on any interface"
fi

if command -v networkctl >/dev/null 2>&1; then
    if networkctl --no-legend 2>/dev/null | grep -qw routable; then
        say_pass "networkctl reports a routable link"
    else
        say_fail "networkctl: no routable link"
        networkctl --no-legend 2>/dev/null | sed 's/^/      /'
    fi
fi

# ---------------------------------------------------------------------------
section "Image / OTA identity"
check_match "/etc/os-release reports iotgw" 'iotgw|IoT Gateway' cat /etc/os-release
check_match "/etc/machine-id is non-zero"   '^[0-9a-f]{32}$' cat /etc/machine-id
if [ -r /etc/buildinfo ]; then
    printf '    buildinfo:\n'
    head -10 /etc/buildinfo | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
section "Quick dmesg sanity"
# Allowlist known-benign RPi5 noise:
#   - brcm-pcie link down on the unused PCIe controller
#   - dw_spi_mmio DMA init failure (driver falls back to PIO, SPI still works)
#   - Infineon SLB9670/9672 self-test error (256) — kernel does manual startup, recovers
benign='brcm-pcie.*link down|dw_spi_mmio.*DMA init failed|tpm tpm0: A TPM error \(256\) occurred attempting the self test|no PMU driver|will be ignored'
err_count=$(journalctl -k -p err --no-pager -b 2>/dev/null | grep -vE "$benign" | wc -l)
if [ "$err_count" -eq 0 ]; then
    say_pass "no kernel errors at level err+ this boot"
else
    say_fail "$err_count kernel error lines this boot (journalctl -k -p err -b)"
    journalctl -k -p err --no-pager -b 2>/dev/null | head -10 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
section "SELinux (active MAC)"
# This distro ships SELinux as the always-on MAC in PERMISSIVE mode
# (DEFAULT_ENFORCING=permissive): AVC denials are logged, nothing is blocked,
# until policy coverage is validated. Kernel LSM stack lives in
# security-prod.cfg; userspace/policy (refpolicy-mcs + core-selinux tools)
# via packagegroup-iot-gw-selinux. The rootfs is labeled at build time
# (selinux-image), so no first-boot autorelabel should be pending.
# See docs/SELINUX.md.
if [ -d /sys/fs/selinux ] && [ -e /sys/fs/selinux/enforce ]; then
    say_pass "selinuxfs present (/sys/fs/selinux) — SELinux enabled in kernel"
else
    say_fail "/sys/fs/selinux/enforce absent — SELinux not enabled (check CONFIG_LSM / selinux=0?)"
fi

# Kernel LSM stack must list selinux (CONFIG_LSM=...,selinux)
if [ -r /sys/kernel/security/lsm ]; then
    lsm=$(cat /sys/kernel/security/lsm 2>/dev/null)
    if printf '%s' "$lsm" | grep -qw selinux; then
        say_pass "selinux active in kernel LSM stack ($lsm)"
    else
        say_fail "selinux absent from LSM stack ($lsm)"
    fi
else
    say_skip "/sys/kernel/security/lsm" "securityfs not readable"
fi

# Current enforcing mode — PERMISSIVE is the expected baseline
if command -v getenforce >/dev/null 2>&1; then
    mode=$(getenforce 2>/dev/null)
    case "$mode" in
        Permissive) say_pass "getenforce: Permissive (expected baseline)" ;;
        Enforcing)  say_pass "getenforce: Enforcing (stricter than baseline — note)" ;;
        Disabled)   say_fail "getenforce: Disabled — SELinux not active at runtime" ;;
        *)          say_fail "getenforce: unexpected value '$mode'" ;;
    esac
else
    say_fail "getenforce not installed — SELinux userspace missing (packagegroup-iot-gw-selinux)"
fi

# Loaded policy identity + status
if command -v sestatus >/dev/null 2>&1; then
    sestatus 2>/dev/null | sed 's/^/    /'
    if sestatus 2>/dev/null | grep -qiE 'SELinux status:[[:space:]]*enabled'; then
        say_pass "sestatus: SELinux status enabled"
    else
        say_fail "sestatus: SELinux not enabled"
    fi
else
    say_skip "sestatus" "policycoreutils not installed"
fi

# Core userspace tools (packagegroup-core-selinux) must be present
for tool in getenforce setenforce sestatus semodule restorecon; do
    if command -v "$tool" >/dev/null 2>&1; then
        say_pass "selinux tool present: $tool"
    else
        say_fail "selinux tool missing: $tool (packagegroup-iot-gw-selinux incomplete)"
    fi
done
# setools (seinfo/sesearch) is optional policy-analysis tooling
for tool in seinfo sesearch; do
    if command -v "$tool" >/dev/null 2>&1; then
        say_pass "setools present: $tool"
    else
        say_skip "setools $tool" "setools not installed on this image"
    fi
done

# Rootfs labeling: build-time (selinux-image) ⇒ no autorelabel pending, and
# shipped files carry real contexts (not unlabeled_t).
if [ -e /.autorelabel ]; then
    say_fail "/.autorelabel present — full relabel pending (build-time labeling expected)"
else
    say_pass "no /.autorelabel pending (rootfs labeled at build)"
fi
ctx=$(stat -c %C /etc/passwd 2>/dev/null)
case "$ctx" in
    *unlabeled_t*) say_fail "/etc/passwd is unlabeled_t — rootfs labeling did not run" ;;
    *_t:*|*_t)     say_pass "/etc/passwd labeled: $ctx" ;;
    ""|'?')        say_skip "/etc/passwd context" "stat has no SELinux context support" ;;
    *)             say_skip "/etc/passwd context" "unexpected context '$ctx'" ;;
esac

# AVC denials this boot — informational in permissive mode (logged, not blocked).
# Surfaced for policy triage before any enforcing flip; not a failure here.
if command -v journalctl >/dev/null 2>&1; then
    avc=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'avc:[[:space:]]*denied')
    if [ "${avc:-0}" -eq 0 ]; then
        say_pass "no AVC denials logged this boot"
    else
        say_skip "AVC denials" "$avc this boot — review before enforcing (journalctl -k -b | grep 'avc:  denied')"
    fi
fi

# ---------------------------------------------------------------------------
section "eBPF / tracing (observability-dev)"
# igw_observability_dev enables the BPF tracing/probe surface (BPF_EVENTS,
# KPROBES/UPROBES, FTRACE); bpftool ships via recipes-kernel/bpftool. These are
# dev-observability features — SKIP (not FAIL) when the fragment/tool is not in
# the built image (e.g. a hardened prod variant).
if command -v bpftool >/dev/null 2>&1; then
    say_pass "bpftool present"
    if bpftool version >/dev/null 2>&1; then
        bpftool version 2>/dev/null | sed 's/^/    /'
        say_pass "bpftool version responds"
    else
        say_fail "bpftool present but 'bpftool version' failed"
    fi
    # prog listing exercises the BPF syscall read path (needs root — script runs as root)
    if bpftool prog show >/dev/null 2>&1; then
        say_pass "bpftool prog show succeeded (BPF syscall reachable)"
    else
        say_fail "bpftool prog show failed — BPF syscall unavailable"
    fi
else
    say_skip "bpftool" "not installed on this image (recipes-kernel/bpftool not built in)"
fi

# BPF JIT enabled (performance + spectre hardening)
if [ -r /proc/sys/net/core/bpf_jit_enable ]; then
    jit=$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null)
    case "$jit" in
        1|2) say_pass "BPF JIT enabled (bpf_jit_enable=$jit)" ;;
        *)   say_fail "BPF JIT disabled (bpf_jit_enable=$jit)" ;;
    esac
else
    say_skip "bpf_jit_enable" "sysctl not present"
fi

# tracefs — required to attach kprobe/uprobe/ftrace events
if mountpoint -q /sys/kernel/tracing 2>/dev/null || mountpoint -q /sys/kernel/debug/tracing 2>/dev/null; then
    say_pass "tracefs mounted"
else
    say_skip "tracefs" "not mounted (mount -t tracefs none /sys/kernel/tracing to use ftrace/kprobes)"
fi

# Kernel tracing kconfig — the observability-dev.cfg symbols. Needs
# CONFIG_IKCONFIG_PROC (/proc/config.gz); SKIP the block if it is absent.
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    cfg=$(zcat /proc/config.gz 2>/dev/null)
    for sym in CONFIG_BPF_EVENTS CONFIG_KPROBES CONFIG_KPROBE_EVENTS \
               CONFIG_UPROBES CONFIG_UPROBE_EVENTS CONFIG_FTRACE CONFIG_FUNCTION_TRACER; do
        if printf '%s\n' "$cfg" | grep -q "^${sym}=y"; then
            say_pass "kconfig ${sym}=y"
        else
            say_fail "kconfig ${sym} not set — observability-dev fragment missing?"
        fi
    done
else
    say_skip "/proc/config.gz" "CONFIG_IKCONFIG_PROC off — cannot verify tracing kconfig on target"
fi

# ---------------------------------------------------------------------------
section "/var narrowing & /data persistence"
# /var is no longer overlaid — it reverts to the stock OE volatile model
# (tmpfs /var/volatile + volatile-binds), with the must-persist state re-homed
# onto dedicated /data-backed binds/redirects. This block asserts the narrowed
# shape; on a pre-narrowing image (/var still overlaid) it SKIPs cleanly.

# Read the true fstype from PID1's view — the SSH session's mount namespace can
# misreport mounts.
vv_fs=$(stat -f -c %T /proc/1/root/var/volatile 2>/dev/null)
[ -z "$vv_fs" ] && vv_fs=$(stat -f -c %T /var/volatile 2>/dev/null)

if [ "$vv_fs" != "tmpfs" ]; then
    say_skip "/var narrowing" "/var/volatile fstype is '${vv_fs:-unknown}' (pre-narrowing image — /var still overlaid)"
else
    say_pass "/var/volatile is a true tmpfs (overlay narrowed)"

    # /var must no longer carry an overlay upper on /data.
    if grep -qE 'upperdir=[^ ,]*/overlays/var/' /proc/1/mountinfo 2>/dev/null; then
        say_fail "/var still has an overlay upper (narrowing incomplete)"
    else
        say_pass "/var is not overlaid (no /data/overlays/var upper)"
    fi

    # Stock volatile-binds now actually run (were condition-skipped under the overlay).
    for u in var-volatile-lib var-volatile-cache var-volatile-spool; do
        if systemctl is-active "${u}.service" >/dev/null 2>&1; then
            say_pass "${u}.service active (stock volatile-binds)"
        else
            say_fail "${u}.service not active — /var/lib may be read-only"
        fi
    done

    # Journal + audit re-homed onto /data-backed binds (read real paths; /var/log
    # is a symlink into /var/volatile/log).
    data_dev=$(findmnt -no SOURCE /data 2>/dev/null)
    for m in /var/volatile/log/journal /var/volatile/log/audit; do
        if findmnt --target "$m" >/dev/null 2>&1; then
            msrc=$(findmnt -no SOURCE --target "$m" 2>/dev/null)
            case "$msrc" in
                "${data_dev}"*|*/data/*) say_pass "$m persisted on /data ($msrc)" ;;
                *) say_fail "$m mounted but not from /data ($msrc)" ;;
            esac
        else
            say_fail "$m is not a bind — journal/audit NOT re-homed to /data"
        fi
    done
    command -v journalctl >/dev/null 2>&1 && du=$(journalctl --disk-usage 2>/dev/null) && [ -n "$du" ] && say_pass "journald: $du"

    # The /data persistence set (must-exist backing dirs).
    for d in /data/log /data/log/journal /data/log/audit /data/ssh /data/mosquitto; do
        if [ -d "$d" ]; then say_pass "backing dir present: $d"; else say_fail "backing dir missing: $d"; fi
    done
    # Feature/state-dependent dirs — SKIP when the feature/pairing has not populated them.
    for d in /data/lib/thread /data/lib/bluetooth /data/tpm2_pkcs11 /data/influxdb3; do
        if [ -d "$d" ]; then say_pass "backing dir present: $d"; else say_skip "backing dir $d" "not created (feature off / no state yet)"; fi
    done

    # No read-only-filesystem errors this boot — the main regression risk of
    # dropping the /var overlay (a writer hitting a bare /var path).
    if command -v journalctl >/dev/null 2>&1; then
        ro=$(journalctl -b --no-pager 2>/dev/null | grep -icE 'read-only file system')
        if [ "${ro:-0}" -eq 0 ]; then
            say_pass "no 'read-only file system' errors this boot"
        else
            say_fail "$ro 'read-only file system' error(s) — a writer hit a bare /var path (journalctl -b | grep -i 'read-only')"
        fi
    fi

    # /var/volatile root label (steady-state z-relabel → var_t).
    vvctx=$(stat -c %C /var/volatile 2>/dev/null)
    case "$vvctx" in
        *:var_t:*|*var_t) say_pass "/var/volatile labeled var_t ($vvctx)" ;;
        *unlabeled_t*)    say_skip "/var/volatile label" "unlabeled_t — z-relabel not yet applied (permissive-harmless)" ;;
        ""|'?')           say_skip "/var/volatile label" "no SELinux context support in stat" ;;
        *)                say_skip "/var/volatile label" "context '$vvctx'" ;;
    esac
fi
# NOTE: general failed-unit / system-state health is covered by the "Systemd
# unit health" section above (which flags a degraded state and hints the
# ota-certs-provision provisioning workflow). Not re-checked here.

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
printf '  PASS: %d\n' "$PASS"
printf '  FAIL: %d\n' "$FAIL"
printf '  SKIP: %d\n' "$SKIP"

[ "$FAIL" -eq 0 ]
