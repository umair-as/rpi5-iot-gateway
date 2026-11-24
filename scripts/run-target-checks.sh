#!/usr/bin/env bash
# Host-side runner for the target-side smoke/check scripts.
#
# The scripts under scripts/{ota,container}/*-target.sh (and
# ota-fit-slot-check.sh) read the DEVICE's own /proc/cmdline, `rauc status`,
# `uname`, /boot, dmesg, etc. — they only produce meaningful results when run
# ON the gateway. Running them directly on your workstation fails at slot
# detection ("could not determine active RAUC slot"). This runner streams each
# one to a live gateway over SSH, preceded by the shared reporting helpers
# ("cat scripts/lib/target-check.sh <script> | ssh <host> 'bash -s'"), and
# aggregates PASS/FAIL, so you drive them from the host with just the device IP.
# Each check ends with one "RESULT pass=<n> fail=<n> skip=<n>" line for
# regression tooling; the runner's own verdict is the check's exit status.
#
# Usage:
#   scripts/run-target-checks.sh <device-host-or-ip> [check ...]
#   IOTGW_TARGET=<device-ip> scripts/run-target-checks.sh
#   scripts/run-target-checks.sh <device-ip> ota-fit-slot ota-smoke
#   scripts/run-target-checks.sh --list
#
# With no check names, runs the default smoke set (platform-smoke ota-fit-slot
# ota-smoke container-smoke exposure). ota-bench (a benchmark, not a pass/fail check) and
# deepx-acceptance (DX-M1 only; it self-skips elsewhere, but a full inference
# run does not belong in a smoke set) are excluded from the default set and can
# be named explicitly. selinux-enforcing is excluded as well: it needs an
# enforcing board and a sysadm_t shell, which an SSH root login (staff_t) does
# not provide; see the script header.
#
# The "exposure" check asserts listen scope, address family, and firewall
# qualification. It cannot test off-device reachability - a device cannot prove
# its own; pair it with scripts/security/exposure-probe-host.sh from a second
# host.
#
# Environment overrides:
#   IOTGW_TARGET     device host/IP (used if no positional host is given)
#   IOTGW_SSH_USER   SSH user (default: root)
#   IOTGW_SSH_OPTS   SSH options, replacing the defaults entirely (default:
#                    host key verified, accept-new; see scripts/lib/host-ssh.sh)
#   IOTGW_KNOWN_HOSTS known_hosts file to verify against (bench-specific)
#   IOTGW_SSH_INSECURE=1 skip host-key verification, explicitly (warns)
#   IOTGW_REMOTE_ENV VAR=value pairs prefixed to the remote shell, for checks
#                    that need a host-derived expectation, e.g.
#                    IOTGW_REMOTE_ENV='IOTGW_DXM1_EXPECT_VERMAGIC=6.18.37-...'
#
# Exit status: 0 if every selected check passed; non-zero if any check
# failed or could not be run (matches each target script's own exit contract).

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Prepended to every check: the device has no copy of the repo to source from.
TARGET_LIB="${SCRIPT_DIR}/lib/target-check.sh"

# check-name -> relative script path (single source of truth for the registry)
check_path() {
    case "$1" in
        platform-smoke)  echo "platform/platform-smoke-target.sh" ;;
        ota-fit-slot)    echo "ota/ota-fit-slot-check.sh" ;;
        ota-smoke)       echo "ota/ota-smoke-target.sh" ;;
        container-smoke) echo "containers/rootless-acceptance-target.sh" ;;
        ota-bench)       echo "ota/ota-bench-target.sh" ;;
        exposure)        echo "security/exposure-target.sh" ;;
        deepx-acceptance) echo "deepx/dxm1-acceptance-target.sh" ;;
        selinux-enforcing) echo "selinux/selinux-enforcing-target.sh" ;;
        overlay-identity) echo "selinux/overlay-identity-target.sh" ;;
        *)               return 1 ;;
    esac
}
ALL_CHECKS="platform-smoke ota-fit-slot ota-smoke container-smoke ota-bench exposure deepx-acceptance selinux-enforcing overlay-identity"
DEFAULT_CHECKS="platform-smoke ota-fit-slot ota-smoke container-smoke exposure"

usage() {
    sed -nE 's/^# ?//p' "${BASH_SOURCE[0]}" | sed -n '1,44p'
}

list_checks() {
    printf 'Available checks (name -> script):\n'
    for c in $ALL_CHECKS; do
        printf '  %-18s %s\n' "$c" "scripts/$(check_path "$c")"
    done
    printf '\nDefault set: %s\n' "$DEFAULT_CHECKS"
}

case "${1:-}" in
    -h|--help)  usage; exit 0 ;;
    --list)     list_checks; exit 0 ;;
esac

# Resolve target host: first positional arg, else IOTGW_TARGET.
TARGET=""
if [ "${1:-}" != "" ] && [ "${1#-}" = "${1:-}" ]; then
    TARGET="$1"
    shift
fi
TARGET="${TARGET:-${IOTGW_TARGET:-}}"
if [ -z "$TARGET" ]; then
    printf 'error: no device host/IP given (pass as first arg or set IOTGW_TARGET)\n\n' >&2
    usage >&2
    exit 2
fi

SSH_USER="${IOTGW_SSH_USER:-root}"
# Host-key policy (strict by default, explicit opt-out): scripts/lib/host-ssh.sh.
# shellcheck source=scripts/lib/host-ssh.sh
. "${SCRIPT_DIR}/lib/host-ssh.sh"
DEFAULT_SSH_OPTS="$(iotgw_ssh_host_key_opts) -o ConnectTimeout=8"
# shellcheck disable=SC2206
SSH_OPTS=(${IOTGW_SSH_OPTS:-$DEFAULT_SSH_OPTS})

# Non-root users need sudo for the privileged checks; root does not.
REMOTE_CMD="bash -s"

# Some checks need a host-derived expectation the device cannot know — the
# DX-M1 acceptance check compares the running kernel against the release the
# flashed image was BUILT with, which is the only way to catch a stale card:
# a stale image is internally self-consistent and passes every other check.
# ssh does not forward the environment, so it is prefixed explicitly.
if [ -n "${IOTGW_REMOTE_ENV:-}" ]; then
    REMOTE_CMD="env ${IOTGW_REMOTE_ENV} ${REMOTE_CMD}"
fi
# sudo goes outermost: it resets the environment of whatever it starts.
[ "$SSH_USER" != "root" ] && REMOTE_CMD="sudo ${REMOTE_CMD}"

# Selected checks: remaining args, else the default set.
if [ "$#" -gt 0 ]; then
    SELECTED="$*"
else
    SELECTED="$DEFAULT_CHECKS"
fi

# Validate names up front so a typo fails fast, before touching the device.
if [ ! -r "$TARGET_LIB" ]; then
    printf 'error: shared helpers missing: scripts/lib/target-check.sh\n' >&2
    exit 2
fi
for c in $SELECTED; do
    if ! rel=$(check_path "$c"); then
        printf "error: unknown check '%s' (see --list)\n" "$c" >&2
        exit 2
    fi
    if [ ! -r "${SCRIPT_DIR}/${rel}" ]; then
        printf "error: check '%s' script missing: %s\n" "$c" "scripts/${rel}" >&2
        exit 2
    fi
done

printf '== target-checks on %s@%s ==\n' "$SSH_USER" "$TARGET"

overall_rc=0
ran=0
failed_list=""
for c in $SELECTED; do
    rel=$(check_path "$c")
    script="${SCRIPT_DIR}/${rel}"
    printf '\n────────────────────────────────────────\n# check: %s  (scripts/%s)\n────────────────────────────────────────\n' "$c" "$rel"
    # Data a check reads from the repo travels in the same stream, as a
    # quoted heredoc assignment ahead of the script.
    data=""
    case "$c" in
        exposure) data="${SCRIPT_DIR}/security/listen-allowlist.txt" ;;
    esac
    if {
        cat "$TARGET_LIB"
        if [ -n "$data" ]; then
            printf "IOTGW_LISTEN_ALLOWLIST=\$(cat <<'IOTGW_DATA_EOF'\n"
            cat "$data"
            printf "\nIOTGW_DATA_EOF\n)\n"
        fi
        cat "$script"
    } | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET}" "$REMOTE_CMD"; then
        printf '# check %s: PASS\n' "$c"
    else
        rc=$?
        printf '# check %s: FAIL (exit %d)\n' "$c" "$rc"
        overall_rc=1
        failed_list="${failed_list} ${c}"
    fi
    ran=$((ran + 1))
done

printf '\n==================== RESULT ====================\n'
printf 'ran %d check(s) on %s\n' "$ran" "$TARGET"
if [ "$overall_rc" -eq 0 ]; then
    printf 'ALL PASSED\n'
else
    printf 'FAILED:%s\n' "$failed_list"
fi
exit "$overall_rc"
