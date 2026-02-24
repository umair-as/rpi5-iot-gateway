#!/usr/bin/env bash
set -euo pipefail

# Run getEnergyScanTask and poll action status.
#
# Usage:
#   scripts/ot-demo/otbr-api-energy-scan.sh
#   scripts/ot-demo/otbr-api-energy-scan.sh --channels 11,12,13,14 --count 1 --period 32
#   BASE_URL=http://192.168.0.82:8081 scripts/ot-demo/otbr-api-energy-scan.sh

BASE_URL="${BASE_URL:-http://127.0.0.1:8081}"
JQ="${JQ:-jq}"
CURL="${CURL:-curl}"

CHANNELS="${CHANNELS:-11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26}"
COUNT="${COUNT:-1}"
PERIOD="${PERIOD:-32}"
SCAN_DURATION="${SCAN_DURATION:-11}"
TIMEOUT="${TIMEOUT:-120}"
DESTINATION="${DESTINATION:-}"
DEST_TYPE="${DEST_TYPE:-extended}"
POLL_SEC="${POLL_SEC:-1}"

usage() {
    cat <<'EOF'
Usage: scripts/ot-demo/otbr-api-energy-scan.sh [options]

Options:
  --channels <csv>      Channel list, e.g. 11,12,13 (default: 11..26)
  --count <n>           Sample count (default: 1)
  --period <n>          Period in ms (default: 32)
  --scan-duration <n>   Scan duration (default: 11)
  --timeout <n>         Action timeout in seconds (default: 120)
  --destination <hex>   16-hex extAddress; if omitted, read from /api/node
  --dest-type <name>    destinationType (default: extended)
  --poll-sec <n>        Poll interval seconds (default: 1)
  -h, --help            Show help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --channels) CHANNELS="$2"; shift 2 ;;
        --count) COUNT="$2"; shift 2 ;;
        --period) PERIOD="$2"; shift 2 ;;
        --scan-duration) SCAN_DURATION="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --destination) DESTINATION="$2"; shift 2 ;;
        --dest-type) DEST_TYPE="$2"; shift 2 ;;
        --poll-sec) POLL_SEC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if ! command -v "${JQ}" >/dev/null 2>&1; then
    echo "ERROR: jq not found" >&2
    exit 1
fi

tmp_node="$(mktemp)"
tmp_post="$(mktemp)"
tmp_get="$(mktemp)"
trap 'rm -f "${tmp_node}" "${tmp_post}" "${tmp_get}"' EXIT

if [ -z "${DESTINATION}" ]; then
    "${CURL}" -sS "${BASE_URL}/api/node" > "${tmp_node}"
    DESTINATION="$("${JQ}" -r '.data.attributes.extAddress // empty' < "${tmp_node}")"
fi

if ! printf '%s' "${DESTINATION}" | grep -Eq '^[0-9a-fA-F]{16}$'; then
    echo "ERROR: destination must be 16 hex chars (got '${DESTINATION}')" >&2
    exit 1
fi

channels_json="$(printf '%s' "${CHANNELS}" | "${JQ}" -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0)) | map(tonumber)')"

payload="$("${JQ}" -cn \
  --arg destination "${DESTINATION}" \
  --arg destType "${DEST_TYPE}" \
  --argjson channelMask "${channels_json}" \
  --argjson count "${COUNT}" \
  --argjson period "${PERIOD}" \
  --argjson scanDuration "${SCAN_DURATION}" \
  --argjson timeout "${TIMEOUT}" \
  '{data:[{type:"getEnergyScanTask",attributes:{destination:$destination,destinationType:$destType,channelMask:$channelMask,count:$count,period:$period,scanDuration:$scanDuration,timeout:$timeout}}]}'
)"

echo "[otbr-api-energy-scan] destination=${DESTINATION}"
echo "[otbr-api-energy-scan] channels=${CHANNELS}"
echo "[otbr-api-energy-scan] POST ${BASE_URL}/api/actions"

post_code="$("${CURL}" -sS -o "${tmp_post}" -w '%{http_code}' \
  -H 'Content-Type: application/vnd.api+json' \
  -H 'Accept: application/vnd.api+json' \
  -d "${payload}" \
  "${BASE_URL}/api/actions")"

if [ "${post_code}" -lt 200 ] || [ "${post_code}" -ge 300 ]; then
    echo "ERROR: HTTP ${post_code}" >&2
    cat "${tmp_post}" >&2
    exit 1
fi

action_id="$("${JQ}" -r '.data[0].id // empty' < "${tmp_post}")"
if [ -z "${action_id}" ]; then
    echo "ERROR: action id missing" >&2
    cat "${tmp_post}" >&2
    exit 1
fi

echo "[otbr-api-energy-scan] action_id=${action_id}"
echo "[otbr-api-energy-scan] polling..."

while :; do
    get_code="$("${CURL}" -sS -o "${tmp_get}" -w '%{http_code}' \
      -H 'Accept: application/vnd.api+json' \
      "${BASE_URL}/api/actions/${action_id}")"
    if [ "${get_code}" -lt 200 ] || [ "${get_code}" -ge 300 ]; then
        echo "ERROR: GET action HTTP ${get_code}" >&2
        cat "${tmp_get}" >&2
        exit 1
    fi

    status="$("${JQ}" -r '.data.attributes.status // "unknown"' < "${tmp_get}")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[${now}] status=${status}"

    case "${status}" in
        completed|failed|stopped)
            break
            ;;
        *)
            sleep "${POLL_SEC}"
            ;;
    esac
done

echo "[otbr-api-energy-scan] final action:"
"${JQ}" '.data' < "${tmp_get}"

echo "[otbr-api-energy-scan] report:"
"${JQ}" '.data.attributes.report // []' < "${tmp_get}"
