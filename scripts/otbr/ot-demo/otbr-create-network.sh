#!/usr/bin/env bash
set -euo pipefail

# Create and start a Thread network on OTBR using ot-ctl.
#
# Env/config (defaults shown):
#   OTCTL=ot-ctl                         # Path to ot-ctl
#   NETWORK_NAME="OpenThread-$(printf %04X $RANDOM)"
#   CHANNEL=18                           # 11..26
#   PANID=$(printf "0x%04x" $((RANDOM & 0xFFFF)))
#   EXTPANID="$(hexdump -vn8 -e '8/1 "%02x"' /dev/urandom)"   # 16 hex chars
#   NETWORK_KEY=""                       # 32 hex chars (optional)

OTCTL=${OTCTL:-ot-ctl}
NETWORK_NAME=${NETWORK_NAME:-OpenThread-$(printf %04X $RANDOM)}
CHANNEL=${CHANNEL:-18}
PANID=${PANID:-$(printf "0x%04x" $((RANDOM & 0xFFFF)))}
EXTPANID=${EXTPANID:-$(hexdump -vn8 -e '8/1 "%02x"' /dev/urandom)}
NETWORK_KEY=${NETWORK_KEY:-}

cmd() { echo ">$*"; $OTCTL "$@"; }
wait_state() {
  local target=${1:-leader}
  for _ in $(seq 1 30); do
    state=$($OTCTL state | tr -d '\r') || true
    echo "state=$state"
    [[ "$state" == "$target" || "$state" == router || "$state" == child ]] && return 0
    sleep 1
  done
  echo "WARN: target state '$target' not reached" >&2
  return 0
}

echo "=== Creating Thread network on OTBR ==="
cmd dataset init new
cmd dataset networkname "$NETWORK_NAME"
cmd dataset channel "$CHANNEL"
cmd dataset panid "$PANID"
cmd dataset extpanid "$EXTPANID"
if [[ -n "$NETWORK_KEY" ]]; then
  cmd dataset networkkey "$NETWORK_KEY"
fi
cmd dataset commit active
cmd ifconfig up
cmd thread start
wait_state leader
echo "=== Active dataset ==="
$OTCTL dataset active
echo "Done"

