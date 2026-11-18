#!/bin/sh
# sshd host keys for this boot, in /run/sshd-keys (the HostKey paths in
# sshd_config_readonly).
#
# The persistent copy is /data/ssh, so the host identity survives reboots and
# A/B updates. sshd reads the keys from /run instead of /data so that a boot
# without /data (pre-init marked it degraded) still gets an SSH server: the
# keys are then generated here for this boot only, and the client sees a
# changed host key, which is the honest signal that the device is not in its
# normal state. With /data mounted, missing or unusable keys are generated into
# /data first and then copied, so they persist.
#
# /data is untrusted input: a symlinked directory or key file is never
# followed, and a key is used only if ssh-keygen can load it. RSA keys shorter
# than RSA_BITS are replaced once. sshdgenkeys.service still runs after this
# and finds every key present.
set -u

RUN_DIR=/run/sshd-keys
PERSIST_DIR=/data/ssh
TYPES="rsa ecdsa ed25519"
RSA_BITS=4096

log() { echo "iotgw-sshd-keys: $*"; }

usable() {
    k=$1
    [ -f "$k" ] && [ ! -L "$k" ] && [ -f "$k.pub" ] && [ ! -L "$k.pub" ] || return 1
    ssh-keygen -y -f "$k" >/dev/null 2>&1 || return 1
    case $k in
        *_rsa_key)
            bits=$(ssh-keygen -l -f "$k.pub" 2>/dev/null | cut -d' ' -f1)
            [ "${bits:-0}" -ge "$RSA_BITS" ] || return 1
            ;;
    esac
}

# <type> <key path>: generate next to the target, then rename, so a power cut
# never leaves a half-written key under the final name.
generate() {
    t=$1
    k=$2
    rm -f "$k.tmp" "$k.tmp.pub"
    case $t in
        rsa) ssh-keygen -q -t rsa -b "$RSA_BITS" -N '' -C '' -f "$k.tmp" ;;
        *)   ssh-keygen -q -t "$t" -N '' -C '' -f "$k.tmp" ;;
    esac || return 1
    rm -f "$k" "$k.pub"
    mv -f "$k.tmp.pub" "$k.pub" && mv -f "$k.tmp" "$k" || return 1
    sync
}

rm -rf "$RUN_DIR"
install -d -m 0700 "$RUN_DIR" || exit 1
command -v restorecon >/dev/null 2>&1 && restorecon "$RUN_DIR"

persist=0
if mountpoint -q /data && [ ! -L "$PERSIST_DIR" ]; then
    if [ -d "$PERSIST_DIR" ] || install -d -m 0700 "$PERSIST_DIR"; then
        persist=1
        command -v restorecon >/dev/null 2>&1 && restorecon "$PERSIST_DIR"
    fi
fi

rc=0
for t in $TYPES; do
    name=ssh_host_${t}_key
    if [ "$persist" = 1 ]; then
        if ! usable "$PERSIST_DIR/$name"; then
            log "generating $t host key in $PERSIST_DIR"
            generate "$t" "$PERSIST_DIR/$name" || { log "cannot write $PERSIST_DIR/$name"; rc=1; continue; }
        fi
        cp "$PERSIST_DIR/$name" "$RUN_DIR/$name" && cp "$PERSIST_DIR/$name.pub" "$RUN_DIR/$name.pub" || rc=1
    else
        generate "$t" "$RUN_DIR/$name" || rc=1
    fi
done
[ "$persist" = 1 ] || log "no usable /data: host keys generated for this boot only"

chmod 0600 "$RUN_DIR"/ssh_host_*_key 2>/dev/null
chmod 0644 "$RUN_DIR"/ssh_host_*_key.pub 2>/dev/null
command -v restorecon >/dev/null 2>&1 && restorecon -R "$RUN_DIR"
exit "$rc"
