#!/bin/bash
# Container-runtime smoke for the IoT Gateway distro (iotgw).
#
# Confirms the podman stack shipped by IOTGW_ENABLE_CONTAINERS is
# actually runnable on target: binaries present, kernel prerequisites
# (cgroup v2 controllers, overlayfs, veth, nftables) compiled in,
# podman storage/network sanity, and — when a registry is reachable —
# a real pull/run/teardown cycle. Exits non-zero on any failure;
# skips (not fails) the online section when the device is offline.
#
# Image-hardening awareness:
#   - SSH sessions run with RestrictNamespaces=yes, so podman cannot
#     unshare mount namespaces from an SSH shell ("creating mount
#     namespace before pivot: operation not permitted"). Lifecycle
#     commands are routed through `systemd-run --pipe` (PID1 context)
#     whenever namespace creation is blocked in the current shell.
#   - The rootfs is read-only and /tmp is per-session (PrivateTmp):
#     nothing here writes outside /tmp within a single invocation, and
#     nothing is expected to persist across invocations.
#
# Usage:
#   # On target directly:
#   sudo ./container-smoke-target.sh
#
#   # From host over SSH (no copy needed):
#   ssh <gw> 'sudo bash -s' < scripts/container/container-smoke-target.sh
#
# Pairs with:
#   scripts/ota/ota-smoke-target.sh — post-OTA / BSP smoke

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

# Detect whether this shell may create mount namespaces (sshd hardening
# sets RestrictNamespaces=yes); if not, run podman via PID1's context.
if unshare -m true 2>/dev/null; then
    PODMAN() { podman "$@"; }
    NS_NOTE="direct"
else
    PODMAN() { systemd-run --pipe --wait --collect -q podman "$@"; }
    NS_NOTE="via systemd-run (namespaces restricted in this shell)"
fi

# Kernel config lookup via ikconfig (/proc/config.gz ships in all variants)
check_kconfig() {
    local name="$1" opt="$2" want="${3:-[ym]}"
    if [ ! -r /proc/config.gz ]; then say_skip "$name" "/proc/config.gz absent"; return; fi
    if zcat /proc/config.gz | grep -qE "^${opt}=${want}\$"; then say_pass "$name"
    else say_fail "$name (${opt}=${want} not in running kernel)"; fi
}

# ---------------------------------------------------------------------------
section "Container stack presence"
if ! command -v podman >/dev/null 2>&1; then
    say_skip "container stack" "podman not installed (IOTGW_ENABLE_CONTAINERS off?)"
    printf '\nSummary: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
fi
check "podman binary" command -v podman
check "crun OCI runtime" command -v crun
check "netavark network backend" sh -c 'command -v netavark || test -x /usr/libexec/podman/netavark'
check "aardvark-dns" sh -c 'command -v aardvark-dns || test -x /usr/libexec/podman/aardvark-dns'
# Image tools are a separate gate (IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS)
if command -v buildah >/dev/null 2>&1; then
    check "buildah (image tools)" command -v buildah
    check "skopeo (image tools)" command -v skopeo
else
    say_skip "buildah/skopeo" "image-tools gate off"
fi

# ---------------------------------------------------------------------------
section "Kernel prerequisites"
check_kconfig "cgroup v2 freezer/pids" "CONFIG_CGROUPS" "y"
check_match "cgroup2 unified hierarchy" "cgroup2" findmnt -n -o FSTYPE /sys/fs/cgroup
check_match "cpu/memory/pids controllers delegated" "cpu.*memory.*pids|memory.*pids" \
    cat /sys/fs/cgroup/cgroup.controllers
check_match "overlayfs available" "overlay" cat /proc/filesystems
check_kconfig "veth pair support" "CONFIG_VETH"
check_kconfig "network namespaces" "CONFIG_NET_NS" "y"
check_kconfig "nftables (netavark port fwd)" "CONFIG_NF_TABLES"

# ---------------------------------------------------------------------------
section "Podman runtime sanity"
check "podman info" podman info
check_match "storage driver is overlay" '"?overlay"?' \
    podman info --format '{{.Store.GraphDriverName}}'
check_match "OCI runtime is crun" 'crun' \
    podman info --format '{{.Host.OCIRuntime.Name}}'
graphroot=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)
if [ -n "$graphroot" ] && touch "$graphroot/.smoke-write-test" 2>/dev/null; then
    rm -f "$graphroot/.smoke-write-test"
    say_pass "graphroot writable ($graphroot)"
else
    say_fail "graphroot writable (${graphroot:-unknown})"
fi
check_match "default podman network exists" '\bpodman\b' podman network ls --format '{{.Name}}'

# ---------------------------------------------------------------------------
section "Container lifecycle (online, $NS_NOTE)"
REGISTRY_PROBE_HOST="registry-1.docker.io"
TEST_IMAGE="${TEST_IMAGE:-docker.io/library/alpine:latest}"
if ! timeout 8 sh -c "exec 3<>/dev/tcp/${REGISTRY_PROBE_HOST}/443" 2>/dev/null; then
    say_skip "pull/run cycle" "no route to ${REGISTRY_PROBE_HOST}:443 (offline?)"
else
    if timeout 180 bash -c "$(declare -f PODMAN); PODMAN pull -q $TEST_IMAGE" >/dev/null 2>&1; then
        say_pass "podman pull $TEST_IMAGE"
        check_match "podman run (stdout roundtrip)" 'iotgw-container-ok' \
            PODMAN run --rm "$TEST_IMAGE" echo iotgw-container-ok
        check_match "container network + DNS (netavark/aardvark)" 'inet ' \
            PODMAN run --rm "$TEST_IMAGE" ip -4 addr show eth0
        check "container exit-code propagation" \
            bash -c "$(declare -f PODMAN); ! PODMAN run --rm $TEST_IMAGE sh -c 'exit 7'"
        # Teardown: containers are --rm; keep the image cached for faster reruns
        # unless the operator exported SMOKE_RMI=1.
        if [ "${SMOKE_RMI:-0}" = "1" ]; then
            check "podman rmi (cleanup)" PODMAN rmi "$TEST_IMAGE"
        fi
    else
        say_fail "podman pull $TEST_IMAGE"
    fi
fi

# ---------------------------------------------------------------------------
printf '\nSummary: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
