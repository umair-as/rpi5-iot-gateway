#!/bin/bash
# Push a DX-M1 model to a gateway for the acceptance inference run.
#
# Headless images (dev) ship the confined inference probe (iotgw-dx-demo-probe)
# but no model. This copies one to the place the probe and
# dxm1-acceptance-target.sh look first, /var/cache/dxdemo/probe-model.dxnn,
# owned by the probe account. /var/cache is a volatile overlay: the model is
# gone at the next boot, so push it again after a reboot or an OTA.
#
# Usage:
#   scripts/deepx/dxm1-push-model.sh <host> [model.dxnn]
#     host   board address; logs in as $IOTGW_SSH_USER (default devel), which
#            needs sudo to sysadm_t
#     model  default: YoloV5S_PPU.dxnn from the layer's dx-stream-sample
#            tarball (the same model the desktop image ships)
# Then:
#   IOTGW_SSH_USER=devel scripts/run-target-checks.sh <host> deepx-acceptance

set -eu

HOST=${1:?usage: dxm1-push-model.sh <host> [model.dxnn]}
MODEL=${2:-}
SSH_USER=${IOTGW_SSH_USER:-devel}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DEST=/var/cache/dxdemo/probe-model.dxnn
SSH_OPTS="-o BatchMode=yes -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

if [ -z "$MODEL" ]; then
    TARBALL=$(ls "$REPO"/.kas/meta-deepx-m1/recipes-runtime/dx-stream-sample/files/dx-stream-sample_*.tar.gz 2>/dev/null | sort -V | tail -1)
    [ -n "$TARBALL" ] || { echo "error: no dx-stream-sample tarball under .kas/meta-deepx-m1 (run a parse first, or pass a model)" >&2; exit 2; }
    tar -xzf "$TARBALL" -C "$WORK" ./YoloV5S_PPU.dxnn
    MODEL=$WORK/YoloV5S_PPU.dxnn
    echo "model: YoloV5S_PPU.dxnn from $(basename "$TARBALL")"
fi
[ -r "$MODEL" ] || { echo "error: cannot read $MODEL" >&2; exit 2; }
WANT=$(sha256sum "$MODEL" | cut -d' ' -f1)

# shellcheck disable=SC2086
scp -q $SSH_OPTS "$MODEL" "$SSH_USER@$HOST:/tmp/iotgw-probe-model.dxnn"
# The copy lands in the cache directory's type (iotgw_dxdemo_cache_t), which
# the probe domain may read; restorecon makes that explicit.
# shellcheck disable=SC2086
GOT=$(ssh $SSH_OPTS "$SSH_USER@$HOST" "sudo -n sh -c '
    id dxdemo >/dev/null 2>&1 && [ -d /var/cache/dxdemo ] || { rm -f /tmp/iotgw-probe-model.dxnn; echo \"no probe on this image (iotgw-dx-demo-probe missing)\" >&2; exit 3; }
    install -o dxdemo -g dxdemo -m 0644 /tmp/iotgw-probe-model.dxnn $DEST &&
    rm -f /tmp/iotgw-probe-model.dxnn && restorecon $DEST &&
    sha256sum $DEST | cut -d\" \" -f1' </dev/null")
if [ "$GOT" = "$WANT" ]; then
    echo "pushed: $HOST:$DEST sha256 $WANT"
else
    echo "error: checksum mismatch on $HOST ($GOT, expected $WANT)" >&2
    exit 1
fi
