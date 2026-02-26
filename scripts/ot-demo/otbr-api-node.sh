#!/usr/bin/env bash
set -euo pipefail

# Fetch OTBR REST /api/node and print key fields.
#
# Usage:
#   scripts/ot-demo/otbr-api-node.sh
#   BASE_URL=http://192.168.0.82:8081 scripts/ot-demo/otbr-api-node.sh

BASE_URL="${BASE_URL:-http://127.0.0.1:8081}"
JQ="${JQ:-jq}"
CURL="${CURL:-curl}"

if ! command -v "${JQ}" >/dev/null 2>&1; then
    echo "ERROR: jq not found" >&2
    exit 1
fi

echo "[otbr-api-node] GET ${BASE_URL}/api/node"
"${CURL}" -sS "${BASE_URL}/api/node" | "${JQ}" '{
  id: .data.id,
  type: .data.type,
  state: .data.attributes.state,
  role: .data.attributes.role,
  networkName: .data.attributes.networkName,
  extAddress: .data.attributes.extAddress,
  extPanId: .data.attributes.extPanId,
  rloc16: .data.attributes.rloc16,
  routerCount: .data.attributes.routerCount,
  created: .data.attributes.created
}'
