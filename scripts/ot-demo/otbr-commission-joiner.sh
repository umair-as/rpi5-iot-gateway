#!/usr/bin/env bash
set -euo pipefail

# Start native Commissioner on OTBR and authorize a Joiner using PSKd.
#
# Usage:
#   PSKD=J01NME JOINER_EUI64=* ./otbr-commission-joiner.sh
#
# Env/config (required/optional):
#   PSKD=J01NME                 # Joiner passcode (PSKd) shown on Joiner device
#   JOINER_EUI64=*              # Joiner EUI-64 ("*" to allow any)
#   TIMEOUT=180                 # Authorization timeout (seconds)
#   OTCTL=ot-ctl                # Path to ot-ctl

OTCTL=${OTCTL:-ot-ctl}
PSKD=${PSKD:-}
JOINER_EUI64=${JOINER_EUI64:-*}
TIMEOUT=${TIMEOUT:-180}

if [[ -z "$PSKD" ]]; then
  echo "ERROR: PSKD is required. Example: PSKD=J01NME $0" >&2
  exit 1
fi

cmd() { echo ">$*"; $OTCTL "$@"; }

echo "=== Starting Commissioner ==="
cmd commissioner start
sleep 1
cmd commissioner state

echo "=== Authorizing Joiner ==="
cmd commissioner joiner add "$JOINER_EUI64" "$PSKD" "$TIMEOUT"
echo "Joiner authorized. Start the Joiner with PSKd on the device within ${TIMEOUT}s."

echo "Commissioner state:" && $OTCTL commissioner state || true
echo "Done"

