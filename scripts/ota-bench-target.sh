#!/usr/bin/env bash
set -u -o pipefail

# Benchmark RAUC install duration on target and emit JSONL records.
#
# Example:
#   ./ota-bench-target.sh /data/verity.raucb /data/crypt.raucb
#   ./ota-bench-target.sh --key /etc/ota/device.key /data/crypt.raucb

OUTPUT_FILE="${OUTPUT_FILE:-/data/ota/bench/rauc-install-bench.jsonl}"
KEY_FILE=""
FORMAT_OVERRIDE=""
LABEL_PREFIX=""

usage() {
    cat <<'EOF'
Usage: ota-bench-target.sh [options] <bundle1.raucb> [bundle2.raucb ...]

Options:
  --output <path>   JSONL output path (default: /data/ota/bench/rauc-install-bench.jsonl)
  --key <path>      Optional key file for `rauc info` format detection
  --format <name>   Override detected format (e.g. verity, crypt)
  --label <text>    Optional label prefix stored in JSON records
  -h, --help        Show this help
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing command: $1" >&2
        exit 1
    }
}

status_field() {
    local key="$1"
    rauc status 2>/dev/null | sed -n "s/^${key}[[:space:]]*//p" | head -n1
}

detect_format() {
    local bundle="$1"
    local info_out
    local fmt=""

    if [ -n "${FORMAT_OVERRIDE}" ]; then
        printf '%s\n' "${FORMAT_OVERRIDE}"
        return 0
    fi

    if [ -n "${KEY_FILE}" ]; then
        info_out="$(rauc info --key="${KEY_FILE}" "${bundle}" 2>&1 || true)"
    else
        info_out="$(rauc info "${bundle}" 2>&1 || true)"
    fi

    fmt="$(printf '%s\n' "${info_out}" | awk '/Bundle Format:/{print $3; exit}')"
    if [ -n "${fmt}" ]; then
        printf '%s\n' "${fmt}"
        return 0
    fi

    if printf '%s\n' "${info_out}" | grep -qi "Encrypted bundle detected"; then
        printf 'crypt\n'
        return 0
    fi

    printf 'unknown\n'
}

main() {
    local bundles=()
    local arg=""

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "${arg}" in
            --output)
                shift
                OUTPUT_FILE="${1:-}"
                [ -n "${OUTPUT_FILE}" ] || { echo "ERROR: --output requires a value" >&2; exit 1; }
                ;;
            --key)
                shift
                KEY_FILE="${1:-}"
                [ -n "${KEY_FILE}" ] || { echo "ERROR: --key requires a value" >&2; exit 1; }
                ;;
            --format)
                shift
                FORMAT_OVERRIDE="${1:-}"
                [ -n "${FORMAT_OVERRIDE}" ] || { echo "ERROR: --format requires a value" >&2; exit 1; }
                ;;
            --label)
                shift
                LABEL_PREFIX="${1:-}"
                [ -n "${LABEL_PREFIX}" ] || { echo "ERROR: --label requires a value" >&2; exit 1; }
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*)
                echo "ERROR: unknown option: ${arg}" >&2
                exit 1
                ;;
            *)
                bundles+=("${arg}")
                ;;
        esac
        shift
    done

    [ "${#bundles[@]}" -gt 0 ] || { usage; exit 1; }

    need_cmd rauc
    need_cmd jq
    need_cmd sha256sum
    need_cmd stat
    need_cmd date
    need_cmd hostname

    mkdir -p "$(dirname "${OUTPUT_FILE}")"
    mkdir -p "/data/ota/bench/logs"

    for bundle in "${bundles[@]}"; do
        if [ ! -f "${bundle}" ]; then
            echo "WARN: skipping missing bundle: ${bundle}" >&2
            continue
        fi

        local start_iso end_iso start_epoch end_epoch duration_s
        local booted_before booted_after activated_before activated_after
        local fmt size sha host label
        local rc result log_file

        start_iso="$(date -Iseconds)"
        start_epoch="$(date +%s)"
        booted_before="$(status_field "Booted from:")"
        activated_before="$(status_field "Activated:")"
        fmt="$(detect_format "${bundle}")"
        size="$(stat -c '%s' "${bundle}")"
        sha="$(sha256sum "${bundle}" | awk '{print $1}')"
        host="$(hostname)"
        label="$(basename "${bundle}")"
        [ -n "${LABEL_PREFIX}" ] && label="${LABEL_PREFIX}:${label}"
        log_file="/data/ota/bench/logs/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "${bundle}").log"

        echo "==> Installing ${bundle}" >&2
        set +e
        rauc install "${bundle}" >"${log_file}" 2>&1
        rc=$?
        set -e

        end_iso="$(date -Iseconds)"
        end_epoch="$(date +%s)"
        duration_s="$((end_epoch - start_epoch))"
        booted_after="$(status_field "Booted from:")"
        activated_after="$(status_field "Activated:")"
        if [ "${rc}" -eq 0 ]; then
            result="success"
        else
            result="failure"
        fi

        jq -n \
            --arg ts "${start_iso}" \
            --arg host "${host}" \
            --arg label "${label}" \
            --arg bundle "${bundle}" \
            --arg bundle_sha256 "${sha}" \
            --arg format "${fmt}" \
            --arg booted_before "${booted_before}" \
            --arg booted_after "${booted_after}" \
            --arg activated_before "${activated_before}" \
            --arg activated_after "${activated_after}" \
            --arg start "${start_iso}" \
            --arg end "${end_iso}" \
            --arg result "${result}" \
            --arg log_file "${log_file}" \
            --arg rauc_version "$(rauc --version | awk '{print $2}')" \
            --argjson bundle_size_bytes "${size}" \
            --argjson duration_s "${duration_s}" \
            --argjson exit_code "${rc}" \
            '{
              ts: $ts,
              host: $host,
              label: $label,
              bundle: $bundle,
              bundle_sha256: $bundle_sha256,
              bundle_size_bytes: $bundle_size_bytes,
              format: $format,
              rauc_version: $rauc_version,
              booted_before: $booted_before,
              activated_before: $activated_before,
              booted_after: $booted_after,
              activated_after: $activated_after,
              start: $start,
              end: $end,
              duration_s: $duration_s,
              exit_code: $exit_code,
              result: $result,
              log_file: $log_file
            }' >> "${OUTPUT_FILE}"

        echo "    result=${result} duration_s=${duration_s} log=${log_file}" >&2
    done

    echo "Wrote benchmark records to ${OUTPUT_FILE}" >&2
}

main "$@"
