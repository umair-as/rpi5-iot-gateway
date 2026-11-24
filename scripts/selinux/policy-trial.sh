#!/usr/bin/env bash
# Try candidate SELinux rules on a dev board without building an image.
#
# Compiles the policy store of the last refpolicy build plus one candidate CIL
# file with secilc, neverallow checks on, proves the check is live with a rule
# that must be rejected, and optionally loads the result on a running board.
# The load lands in the volatile /etc overlay and in the kernel only: a reboot
# restores the image's policy. Runtime semodule cannot commit on these images,
# so this is the way to test a rule before it goes into iotgw.te.
#
# Usage:
#   scripts/selinux/policy-trial.sh <candidate.cil> [--load user@host]
#
# Prerequisites: bitbake refpolicy-mcs -c install and bitbake secilc-native.
# --load needs an account with sudo to sysadm_t on a board running a build of
# the same policy. Development boards only.

set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
CANDIDATE=${1:?usage: policy-trial.sh <candidate.cil> [--load user@host]}
LOAD_TARGET=
if [ "${2:-}" = "--load" ]; then
    LOAD_TARGET=${3:?--load needs user@host}
fi
TMPDIR_ROOT=$(realpath "${BUILDDIR:-build}/tmp")
STORE=$(ls -d "$TMPDIR_ROOT"/work/*/refpolicy-mcs/*/image/var/lib/selinux/mcs/active/modules 2>/dev/null | head -1)
SYSROOT=$TMPDIR_ROOT/sysroots-components/x86_64
SECILC=$SYSROOT/secilc-native/usr/bin/secilc
[ -n "$STORE" ] || { echo "error: no refpolicy store; run bitbake refpolicy-mcs -c install" >&2; exit 2; }
[ -x "$SECILC" ] || { echo "error: no secilc; run bitbake secilc-native" >&2; exit 2; }
export LD_LIBRARY_PATH="$SYSROOT/libsepol-native/usr/lib"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
for f in "$STORE"/*/*/cil; do
    prio=$(basename "$(dirname "$(dirname "$f")")")
    name=$(basename "$(dirname "$f")")
    bunzip2 -c "$f" > "$WORK/$prio-$name.cil" 2>/dev/null || cp "$f" "$WORK/$prio-$name.cil"
done
echo "store: $(find "$WORK" -name '*.cil' | wc -l) modules"
cp "$CANDIDATE" "$WORK/zz-candidate.cil"

cd "$WORK"
"$SECILC" -M true -c 35 -o policy.trial -f fc.out ./*.cil
echo "candidate compiled, neverallow checks passed"

mkdir neg
printf '(allow iotgw_webui_t shadow_t (file (read)))\n' > neg/violation.cil
if neg_out=$("$SECILC" -M true -c 35 -o neg/policy -f neg/fc ./*.cil neg/violation.cil 2>&1); then
    echo "error: a neverallow violation compiled, the check is not active" >&2
    exit 1
fi
case "$neg_out" in
    *neverallow*) ;;
    *) echo "error: negative control failed for another reason: $neg_out" >&2; exit 1 ;;
esac
echo "negative control rejected"

if [ -n "$LOAD_TARGET" ]; then
    # Host-key policy (strict by default, explicit opt-out): scripts/lib/host-ssh.sh.
    # shellcheck source=scripts/lib/host-ssh.sh
    . "$HERE/../lib/host-ssh.sh"
    SSH_OPTS="$(iotgw_ssh_host_key_opts) -o LogLevel=ERROR"
    # shellcheck disable=SC2086
    scp -q $SSH_OPTS policy.trial "$LOAD_TARGET:/tmp/policy.trial"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$LOAD_TARGET" 'sudo -n sh -c "cat /tmp/policy.trial > /etc/selinux/mcs/policy/policy.35 && load_policy && getenforce"'
    echo "loaded on $LOAD_TARGET until its next reboot"
fi
