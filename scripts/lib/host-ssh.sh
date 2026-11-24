# shellcheck shell=bash
# Host-side SSH options shared by the helpers that log in to a gateway
# (run-target-checks.sh, deepx/dxm1-push-model.sh, selinux/policy-trial.sh).
# Sourced on the build host, never sent to the target.
#
# The board's SSH host identity is persistent: generated once into /data/ssh
# and kept across A/B updates (docs/PERSISTENT_STATE.md). A changed host key
# therefore means something: a reflashed card, restricted recovery mode
# without /data, or a different machine answering on that address. Host-key
# checking stays on so that change is reported instead of silently accepted.
#
#   default              StrictHostKeyChecking=accept-new: a first-seen key is
#                        recorded, a changed key is refused.
#   IOTGW_KNOWN_HOSTS    known_hosts file to use instead of ~/.ssh/known_hosts
#                        (a bench-specific file). No spaces in the path.
#   IOTGW_SSH_INSECURE=1 explicit opt-out: no host-key verification. Prints a
#                        warning on every use.
#
# After a deliberate identity change (reflash, recovery mode), drop the old
# key on purpose: ssh-keygen -R <host> [-f "$IOTGW_KNOWN_HOSTS"].

iotgw_ssh_host_key_opts() {
    if [ "${IOTGW_SSH_INSECURE:-0}" = 1 ]; then
        printf 'warning: IOTGW_SSH_INSECURE=1: SSH host key is NOT verified\n' >&2
        printf '%s' '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
        return 0
    fi
    printf '%s' '-o StrictHostKeyChecking=accept-new'
    if [ -n "${IOTGW_KNOWN_HOSTS:-}" ]; then
        printf ' -o UserKnownHostsFile=%s' "$IOTGW_KNOWN_HOSTS"
    fi
}
