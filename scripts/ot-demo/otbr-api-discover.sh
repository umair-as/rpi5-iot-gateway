#!/usr/bin/env bash
set -euo pipefail

# Run updateDeviceCollectionTask and poll action status.
#
# Usage:
#   scripts/ot-demo/otbr-api-discover.sh
#   scripts/ot-demo/otbr-api-discover.sh --device-count 25 --timeout 60
#   BASE_URL=http://192.168.0.82:8081 scripts/ot-demo/otbr-api-discover.sh

BASE_URL="${BASE_URL:-http://127.0.0.1:8081}"
JQ="${JQ:-jq}"
CURL="${CURL:-curl}"

DEVICE_COUNT=10
MAX_AGE=30
MAX_RETRIES=3
TIMEOUT=30
POLL_SEC=1

usage() {
    cat <<'EOF'
Usage: scripts/ot-demo/otbr-api-discover.sh [options]

Options:
  --device-count <n>   Device count target (default: 10)
  --max-age <n>        maxAge attribute (default: 30)
  --max-retries <n>    maxRetries attribute (default: 3)
  --timeout <n>        timeout attribute seconds (default: 30)
  --poll-sec <n>       Poll interval seconds (default: 1)
  -h, --help           Show help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device-count) DEVICE_COUNT="$2"; shift 2 ;;
        --max-age) MAX_AGE="$2"; shift 2 ;;
        --max-retries) MAX_RETRIES="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --poll-sec) POLL_SEC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if ! command -v "${JQ}" >/dev/null 2>&1; then
    echo "ERROR: jq not found" >&2
    exit 1
fi

tmp_post="$(mktemp)"
tmp_get="$(mktemp)"
trap 'rm -f "${tmp_post}" "${tmp_get}"' EXIT

payload="$("${JQ}" -cn \
  --argjson maxAge "${MAX_AGE}" \
  --argjson maxRetries "${MAX_RETRIES}" \
  --argjson deviceCount "${DEVICE_COUNT}" \
  --argjson timeout "${TIMEOUT}" \
  '{data:[{type:"updateDeviceCollectionTask",attributes:{maxAge:$maxAge,maxRetries:$maxRetries,deviceCount:$deviceCount,timeout:$timeout}}]}'
)"

echo "[otbr-api-discover] POST ${BASE_URL}/api/actions"
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

echo "[otbr-api-discover] action_id=${action_id}"
echo "[otbr-api-discover] polling..."

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

echo "[otbr-api-discover] final action:"
"${JQ}" '.data' < "${tmp_get}"

echo "[otbr-api-discover] device collection summary:"
"${CURL}" -sS "${BASE_URL}/api/devices" | "${JQ}" '{
  total: (.meta.collection.total // 0),
  sample: ((.data // [])[0:5] | map({
    id: .id,
    type: .type,
    role: .attributes.role,
    extAddress: .attributes.extAddress
  }))
}'
