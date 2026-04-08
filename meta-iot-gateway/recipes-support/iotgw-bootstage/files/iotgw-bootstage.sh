#!/bin/bash
set -euo pipefail

TAG="iotgw-bootstage"
OUT_DIR="/run/iotgw"
OUT_DIR="${IOTGW_BOOTSTAGE_OUT_DIR:-$OUT_DIR}"
OUT_FILE="${OUT_DIR}/uboot-bootstage.env"
BOOTSTAGE_LOG_LEVEL="${IOTGW_BOOTSTAGE_LOG_LEVEL:-INFO}"

case "${BOOTSTAGE_LOG_LEVEL}" in
    error|ERROR) BOOTSTAGE_LOG_LEVEL="ERROR" ;;
    warn|WARN|warning|WARNING) BOOTSTAGE_LOG_LEVEL="WARN" ;;
    debug|DEBUG) BOOTSTAGE_LOG_LEVEL="DEBUG" ;;
    *) BOOTSTAGE_LOG_LEVEL="INFO" ;;
esac

log_level_num() {
    case "$1" in
        ERROR) echo 0 ;;
        WARN) echo 1 ;;
        INFO) echo 2 ;;
        DEBUG) echo 3 ;;
        *) echo 2 ;;
    esac
}

log_msg() {
    local level="$1"
    local msg="$2"
    local wanted current
    wanted="$(log_level_num "$level")"
    current="$(log_level_num "$BOOTSTAGE_LOG_LEVEL")"
    [ "$wanted" -le "$current" ] || return 0
    logger -t "$TAG" "[iotgw-bootstage][${level}] ${msg}" 2>/dev/null || true
}

read_u32_be() {
    local file="$1"
    od -An -tu1 -N4 "$file" | awk '{print ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4}'
}

find_bootstage_root() {
    if [ -d /proc/device-tree/bootstage ]; then
        echo "/proc/device-tree/bootstage"
        return 0
    fi
    if [ -d /sys/firmware/devicetree/base/bootstage ]; then
        echo "/sys/firmware/devicetree/base/bootstage"
        return 0
    fi
    return 1
}

bootstage_root="${IOTGW_BOOTSTAGE_ROOT:-}"
if [ -z "${bootstage_root}" ]; then
    bootstage_root="$(find_bootstage_root || true)"
fi
if [ -z "${bootstage_root}" ]; then
    log_msg WARN "bootstage DT node not found; verify CONFIG_BOOTSTAGE_FDT=y and iotgw_bootstage=1"
    exit 0
fi

mkdir -p "$OUT_DIR"

record_count=0
max_mark=0
sum_mark=0
summary=""

while IFS= read -r idx; do
    node="${bootstage_root}/${idx}"
    [ -d "$node" ] || continue

    name=""
    if [ -f "$node/name" ]; then
        name="$(tr -d '\000' < "$node/name")"
    fi
    [ -n "$name" ] || name="unknown"

    kind=""
    value=""
    if [ -f "$node/mark" ]; then
        kind="mark"
        value="$(read_u32_be "$node/mark")"
        sum_mark=$((sum_mark + value))
        if [ "$value" -gt "$max_mark" ]; then
            max_mark="$value"
        fi
    elif [ -f "$node/accum" ]; then
        kind="accum"
        value="$(read_u32_be "$node/accum")"
    else
        continue
    fi

    record_count=$((record_count + 1))
    log_msg INFO "stage=${name} kind=${kind} us=${value}"

    if [ "$kind" = "mark" ]; then
        if [ -n "$summary" ]; then
            summary="${summary},"
        fi
        summary="${summary}${name}:${value}"
    fi
done < <(ls -1 "$bootstage_root" 2>/dev/null | awk '/^[0-9]+$/' | sort -n)

if [ "$record_count" -eq 0 ]; then
    log_msg WARN "bootstage node exists but contains no usable records"
    exit 0
fi

cat > "$OUT_FILE" <<EOT
IOTGW_UBOOT_BOOTSTAGE_RECORDS=${record_count}
IOTGW_UBOOT_BOOTSTAGE_MAX_MARK_US=${max_mark}
IOTGW_UBOOT_BOOTSTAGE_SUM_MARK_US=${sum_mark}
IOTGW_UBOOT_BOOTSTAGE_MARKS=${summary}
EOT

log_msg INFO "summary records=${record_count} max_mark_us=${max_mark} sum_mark_us=${sum_mark}"
