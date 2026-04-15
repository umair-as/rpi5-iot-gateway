#!/bin/bash
# SPDX-License-Identifier: MIT
#
# ota-update-check: Poll for OTA updates and trigger RAUC installation
#
# This script:
# 1. Fetches a JSON manifest from the update server (mTLS)
# 2. Compares manifest version against installed RAUC slot
# 3. Triggers 'rauc install <bundle_url>' if update available
# 4. Logs all activity to systemd journal
#

set -euo pipefail

readonly CONFIG_FILE="${OTA_CONFIG:-/etc/ota/updater.conf}"
readonly STATE_DIR="/data/ota"
readonly STATE_FILE="${STATE_DIR}/last-check"
readonly LOCK_FILE="${STATE_DIR}/updater.lock"
readonly RAUC_DBUS_SERVICE="de.pengutronix.rauc"
readonly RAUC_DBUS_PATH="/"
readonly RAUC_DBUS_IFACE="de.pengutronix.rauc.Installer"

# Logging helpers (all to stderr so stdout stays clean for data)
log_info()  { echo "[$(date -Iseconds)] [INFO]  $*" >&2; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $*" >&2; }
die()       { log_error "$*"; exit 1; }

on_err() { log_error "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

rauc_dbus_available() {
    command -v busctl >/dev/null 2>&1 || return 1
    busctl --system call \
        "$RAUC_DBUS_SERVICE" \
        "$RAUC_DBUS_PATH" \
        org.freedesktop.DBus.Peer \
        Ping >/dev/null 2>&1
}

rauc_dbus_get_property_raw() {
    local prop="$1"
    busctl --system get-property \
        "$RAUC_DBUS_SERVICE" \
        "$RAUC_DBUS_PATH" \
        "$RAUC_DBUS_IFACE" \
        "$prop" 2>/dev/null
}

rauc_dbus_get_string_property() {
    local prop="$1"
    local raw
    raw="$(rauc_dbus_get_property_raw "$prop")" || return 1
    echo "$raw" | sed -nE 's/^[^ ]+ "(.*)"$/\1/p'
}

parse_rauc_progress() {
    local raw="$1"
    local pct msg depth
    pct="$(echo "$raw" | awk '{print $2}')"
    depth="$(echo "$raw" | awk '{print $NF}')"
    msg="$(echo "$raw" | sed -nE 's/^\(isi\) [0-9-]+ "(.*)" [0-9-]+$/\1/p')"
    [ -n "$pct" ] || pct=0
    [ -n "$msg" ] || msg="unknown"
    [ -n "$depth" ] || depth=0
    echo "$pct|$msg|$depth"
}

get_system_compatible() {
    local compat=""
    if rauc_dbus_available; then
        compat="$(rauc_dbus_get_string_property Compatible || true)"
    fi
    if [[ -z "$compat" ]]; then
        compat=$(rauc status --output-format=json | jq -r '.compatible // empty')
    fi
    echo "$compat"
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Configuration file not found: $CONFIG_FILE"
    fi

    # Source shell-style config or parse JSON
    if head -1 "$CONFIG_FILE" | grep -q '^{'; then
        # JSON config
        SERVER_URL=$(jq -r '.server_url // empty' "$CONFIG_FILE")
        MANIFEST_PATH=$(jq -r '.manifest_path // "/manifest.json"' "$CONFIG_FILE")
        DEVICE_CERT=$(jq -r '.device_cert // "/etc/ota/device.crt"' "$CONFIG_FILE")
        DEVICE_KEY=$(jq -r '.device_key // "/etc/ota/device.key"' "$CONFIG_FILE")
        DEVICE_KEY_URI=$(jq -r '.device_key_uri // empty' "$CONFIG_FILE")
        DEVICE_KEY_ENGINE=$(jq -r '.device_key_engine // "tpm2tss"' "$CONFIG_FILE")
        CA_CERT=$(jq -r '.ca_cert // "/etc/ota/ca.crt"' "$CONFIG_FILE")
        OPENSSL_CONF_PATH=$(jq -r '.openssl_conf // empty' "$CONFIG_FILE")
        CONNECT_TIMEOUT=$(jq -r '.connect_timeout // 30' "$CONFIG_FILE")
        MAX_TIME=$(jq -r '.max_time // 300' "$CONFIG_FILE")
        FETCH_RETRIES=$(jq -r '.fetch_retries // 5' "$CONFIG_FILE")
        RETRY_BASE_SEC=$(jq -r '.retry_base_sec // 2' "$CONFIG_FILE")
        RETRY_MAX_SEC=$(jq -r '.retry_max_sec // 60' "$CONFIG_FILE")
        DRY_RUN=$(jq -r '.dry_run // false' "$CONFIG_FILE")
    else
        # Shell-style config
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    # Defaults for retry/backoff (shell config can override)
    FETCH_RETRIES=${FETCH_RETRIES:-5}
    RETRY_BASE_SEC=${RETRY_BASE_SEC:-2}
    RETRY_MAX_SEC=${RETRY_MAX_SEC:-60}
    DEVICE_KEY_URI=${DEVICE_KEY_URI:-}
    DEVICE_KEY_ENGINE=${DEVICE_KEY_ENGINE:-tpm2tss}
    OPENSSL_CONF_PATH=${OPENSSL_CONF_PATH:-}

    # Validate required settings
    if [[ -z "${SERVER_URL:-}" ]]; then
        die "SERVER_URL not configured"
    fi
}

# Acquire exclusive lock to prevent concurrent runs
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_warn "Another instance is already running"
        exit 0
    fi
}

# Get currently installed bundle version from RAUC
get_installed_version() {
    local slot_status
    slot_status=$(rauc status --output-format=json 2>/dev/null) || {
        log_error "Failed to get RAUC status"
        return 1
    }

    # Get the booted slot's bundle version
    local booted_slot
    booted_slot=$(echo "$slot_status" | jq -r '.booted // empty')

    if [[ -z "$booted_slot" ]]; then
        log_warn "Could not determine booted slot"
        echo "unknown"
        return 0
    fi

    # Extract version from the booted slot
    local version
    version=$(echo "$slot_status" | jq -r --arg slot "$booted_slot" \
        '.slots[][] | select(.bootname == $slot) | .bundle.version // "unknown"')

    echo "${version:-unknown}"
}

# Fetch manifest from update server using mTLS
fetch_manifest_once() {
    local manifest_url="${SERVER_URL}${MANIFEST_PATH}"
    local key_for_curl=""
    local key_mode="none"
    local key_arg=""
    local -a curl_env=()
    local curl_opts=(
        --silent
        --show-error
        --fail
        --connect-timeout "${CONNECT_TIMEOUT:-30}"
        --max-time "${MAX_TIME:-300}"
    )

    # Add mTLS options if cert/key are configured.
    # key selection precedence:
    #   1. device_key_uri (explicit OpenSSL key URI, e.g. handle:0x81000001)
    #   2. device_key if it points to a file
    #   3. device_key if it looks like a URI scheme
    if [[ -f "${DEVICE_CERT:-}" ]]; then
        if [[ -n "${DEVICE_KEY_URI:-}" ]]; then
            key_arg="${DEVICE_KEY_URI}"
        elif [[ -n "${DEVICE_KEY:-}" && -f "${DEVICE_KEY}" ]]; then
            key_arg="${DEVICE_KEY}"
        elif [[ -n "${DEVICE_KEY:-}" && "${DEVICE_KEY}" == *:* ]]; then
            key_arg="${DEVICE_KEY}"
        fi

        if [[ -n "${key_arg}" ]]; then
            if [[ "${key_arg}" =~ ^handle:(0x[0-9A-Fa-f]+)$ ]]; then
                key_for_curl="${BASH_REMATCH[1]}"
                curl_opts+=(--engine "${DEVICE_KEY_ENGINE}" --key-type ENG --key "${key_for_curl}")
                key_mode="engine"
            elif [[ "${key_arg}" =~ ^0x[0-9A-Fa-f]+$ ]]; then
                key_for_curl="${key_arg}"
                curl_opts+=(--engine "${DEVICE_KEY_ENGINE}" --key-type ENG --key "${key_for_curl}")
                key_mode="engine"
            else
                key_for_curl="${key_arg}"
                curl_opts+=(--key "${key_for_curl}")
                key_mode="file-or-uri"
            fi

            curl_opts+=(--cert "$DEVICE_CERT")
            log_info "Using device certificate: $DEVICE_CERT"
            if [[ "${key_mode}" == "engine" ]]; then
                log_info "Using TPM key via engine: ${DEVICE_KEY_ENGINE} key=${key_for_curl}"
            fi
        else
            log_warn "Device certificate is present but no usable private key/URI configured"
        fi
    elif [[ -n "${DEVICE_CERT:-}" ]]; then
        log_warn "Configured device certificate is missing: ${DEVICE_CERT}"
    fi

    if [[ -n "${OPENSSL_CONF_PATH:-}" ]]; then
        if [[ -r "${OPENSSL_CONF_PATH}" ]]; then
            curl_env+=(OPENSSL_CONF="${OPENSSL_CONF_PATH}")
            log_info "Using OpenSSL config: ${OPENSSL_CONF_PATH}"
        else
            die "Configured openssl_conf is not readable: ${OPENSSL_CONF_PATH}"
        fi
    fi

    if [[ -f "${CA_CERT:-}" ]]; then
        curl_opts+=(--cacert "$CA_CERT")
    fi

    log_info "Fetching manifest from: $manifest_url"
    if [[ ${#curl_env[@]} -gt 0 ]]; then
        env "${curl_env[@]}" curl "${curl_opts[@]}" "$manifest_url"
    else
        curl "${curl_opts[@]}" "$manifest_url"
    fi
}

# Exponential backoff with jitter (seconds)
backoff_sleep() {
    local attempt="$1"
    local base="$2"
    local max="$3"
    local delay=$((base << (attempt - 1)))
    local jitter=0

    if [[ "$delay" -gt "$max" ]]; then
        delay="$max"
    fi

    # Jitter up to 25% of delay
    if [[ "$delay" -gt 0 ]]; then
        jitter=$((RANDOM % (delay / 4 + 1)))
    fi

    sleep $((delay + jitter))
}

# Fetch manifest with retry/backoff
fetch_manifest() {
    local attempt=1
    local max_attempts="$FETCH_RETRIES"
    local manifest=""

    while [[ "$attempt" -le "$max_attempts" ]]; do
        if manifest=$(fetch_manifest_once); then
            echo "$manifest"
            return 0
        fi

        log_warn "Fetch manifest failed (attempt ${attempt}/${max_attempts})"
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            backoff_sleep "$attempt" "$RETRY_BASE_SEC" "$RETRY_MAX_SEC"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# Compare versions (returns 0 if update available)
is_update_available() {
    local installed="$1"
    local available="$2"

    # Simple string comparison - assumes semver or sortable versions
    if [[ "$installed" == "unknown" ]]; then
        log_info "Installed version unknown, will attempt update"
        return 0
    fi

    if [[ "$available" != "$installed" ]]; then
        # Use sort -V for version comparison if available
        local newer
        newer=$(printf '%s\n%s\n' "$installed" "$available" | sort -V | tail -1)
        if [[ "$newer" == "$available" && "$newer" != "$installed" ]]; then
            return 0
        fi
    fi

    return 1
}

# Trigger RAUC installation
install_update() {
    local bundle_url="$1"
    local version="$2"
    local pre_last_error=""
    local op=""
    local progress_raw=""
    local progress_parsed=""
    local progress_pct=0
    local progress_msg="unknown"
    local progress_depth=0
    local progress_msg_lc=""
    local last_error=""
    local timeout_sec=3600
    local start_ts now_ts elapsed

    log_info "Installing update: version=$version url=$bundle_url"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would execute: rauc install '$bundle_url'"
        return 0
    fi

    if rauc_dbus_available; then
        log_info "Using RAUC D-Bus install path"
        pre_last_error="$(rauc_dbus_get_string_property LastError || true)"
        if ! busctl --system call \
            "$RAUC_DBUS_SERVICE" \
            "$RAUC_DBUS_PATH" \
            "$RAUC_DBUS_IFACE" \
            Install s "$bundle_url" >/dev/null 2>&1; then
            log_warn "RAUC D-Bus Install call failed, falling back to CLI"
        else
            start_ts="$(date +%s)"
            while true; do
                op="$(rauc_dbus_get_string_property Operation || true)"
                progress_raw="$(rauc_dbus_get_property_raw Progress || true)"
                progress_parsed="$(parse_rauc_progress "$progress_raw")"
                progress_pct="${progress_parsed%%|*}"
                progress_msg="${progress_parsed#*|}"
                progress_depth="${progress_msg##*|}"
                progress_msg="${progress_msg%|*}"

                log_info "RAUC D-Bus status: operation=${op:-unknown} progress=${progress_pct}% msg='${progress_msg}' depth=${progress_depth}"

                if [[ "$op" == "idle" ]]; then
                    last_error="$(rauc_dbus_get_string_property LastError || true)"
                    progress_msg_lc="$(echo "$progress_msg" | tr '[:upper:]' '[:lower:]')"
                    if [[ -n "$last_error" && "$last_error" != "$pre_last_error" ]]; then
                        log_error "RAUC D-Bus install failed: $last_error"
                        mkdir -p "$STATE_DIR"
                        jq -n \
                            --arg version "$version" \
                            --arg timestamp "$(date -Iseconds)" \
                            --arg error "$last_error" \
                            --arg progress "$progress_msg" \
                            '{version:$version,timestamp:$timestamp,status:"failed",method:"dbus",error:$error,progress:$progress}' \
                            > "${STATE_DIR}/last-update"
                        return 1
                    fi
                    if [[ "$progress_msg_lc" == *failed* || "$progress_msg_lc" == *error* ]]; then
                        log_error "RAUC D-Bus install failed: progress='${progress_msg}'"
                        mkdir -p "$STATE_DIR"
                        jq -n \
                            --arg version "$version" \
                            --arg timestamp "$(date -Iseconds)" \
                            --arg error "RAUC progress indicates failure: ${progress_msg}" \
                            --arg progress "$progress_msg" \
                            '{version:$version,timestamp:$timestamp,status:"failed",method:"dbus",error:$error,progress:$progress}' \
                            > "${STATE_DIR}/last-update"
                        return 1
                    fi

                    if [[ "$progress_msg_lc" == *done* || "$progress_msg_lc" == *complete* || "$progress_pct" == "100" ]]; then
                        log_info "Update installed successfully. Reboot required."
                        mkdir -p "$STATE_DIR"
                        jq -n \
                            --arg version "$version" \
                            --arg timestamp "$(date -Iseconds)" \
                            --arg progress "$progress_msg" \
                            '{version:$version,timestamp:$timestamp,status:"installed",method:"dbus",progress:$progress}' \
                            > "${STATE_DIR}/last-update"
                        return 0
                    fi

                    log_warn "RAUC D-Bus idle without explicit completion marker; treating as success"
                    mkdir -p "$STATE_DIR"
                    jq -n \
                        --arg version "$version" \
                        --arg timestamp "$(date -Iseconds)" \
                        --arg progress "$progress_msg" \
                        '{version:$version,timestamp:$timestamp,status:"installed",method:"dbus",progress:$progress}' \
                        > "${STATE_DIR}/last-update"
                    return 0
                fi

                now_ts="$(date +%s)"
                elapsed=$((now_ts - start_ts))
                if [[ "$elapsed" -ge "$timeout_sec" ]]; then
                    log_error "RAUC D-Bus install timed out after ${timeout_sec}s"
                    return 1
                fi

                sleep 2
            done
        fi
    fi

    log_info "Using RAUC CLI install path"
    if rauc install "$bundle_url"; then
        log_info "Update installed successfully. Reboot required."
        mkdir -p "$STATE_DIR"
        jq -n \
            --arg version "$version" \
            --arg timestamp "$(date -Iseconds)" \
            '{version:$version,timestamp:$timestamp,status:"installed",method:"cli"}' \
            > "${STATE_DIR}/last-update"
        return 0
    fi
    log_error "RAUC installation failed"
    return 1
}

# Record check timestamp
record_check() {
    mkdir -p "$STATE_DIR"
    echo "{\"timestamp\":\"$(date -Iseconds)\",\"server\":\"$SERVER_URL\"}" > "$STATE_FILE"
}

derive_manifest_version() {
    local manifest_json="$1"
    local manifest_entry="$2"
    local v=""

    v=$(echo "$manifest_entry" | jq -r '.version // empty')
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi

    v=$(echo "$manifest_entry" | jq -r '.released_at // empty')
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi

    v=$(echo "$manifest_entry" | jq -r '.filename // empty')
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi

    v=$(echo "$manifest_entry" | jq -r '.sha256 // empty')
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi

    # Fallback for object-only responses that provide a top-level hash/token.
    v=$(echo "$manifest_json" | jq -r '.sha256 // empty')
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi

    echo "unknown"
}

select_manifest_entry() {
    local manifest_json="$1"
    local entry=""

    # Support both:
    # - object manifest: { "bundle_url": "...", ... }
    # - list manifest: [ { "bundle_url": "...", ... }, ... ]
    # For list manifests, prefer active entries when present, then the first item.
    entry="$(echo "$manifest_json" | jq -c '
        if type == "object" then
            .
        elif type == "array" then
            (
              [ .[] | select((.active // true) == true and (.bundle_url // .url // empty) != "") ][0]
              // [ .[] | select((.bundle_url // .url // empty) != "") ][0]
              // .[0]
            )
        else
            empty
        end
    ')"

    if [[ -z "$entry" || "$entry" == "null" ]]; then
        return 1
    fi

    echo "$entry"
}

# Main
main() {
    log_info "OTA update check starting"

    command -v rauc >/dev/null 2>&1 || die "rauc not installed"
    command -v jq >/dev/null 2>&1 || die "jq not installed"
    command -v curl >/dev/null 2>&1 || die "curl not installed"

    load_config
    acquire_lock

    # Get installed version
    local installed_version
    installed_version=$(get_installed_version) || exit 1
    log_info "Installed version: $installed_version"

    # Fetch manifest
    local manifest
    manifest=$(fetch_manifest) || die "Failed to fetch manifest"

    # Parse manifest (supports object and array API shapes)
    local manifest_entry available_version bundle_url compatible
    manifest_entry="$(select_manifest_entry "$manifest")" || die "Invalid manifest: no usable entry"
    available_version="$(derive_manifest_version "$manifest" "$manifest_entry")"
    bundle_url=$(echo "$manifest_entry" | jq -r '.bundle_url // .url // empty')
    compatible=$(echo "$manifest_entry" | jq -r '.compatible // empty')

    if [[ -z "$bundle_url" ]]; then
        die "Invalid manifest: missing bundle_url"
    fi

    log_info "Available version/token: $available_version"

    # Check compatibility if specified in manifest
    if [[ -n "$compatible" ]]; then
        local system_compatible
        system_compatible="$(get_system_compatible)"
        if [[ "$compatible" != "$system_compatible" ]]; then
            die "Bundle not compatible: expected=$system_compatible got=$compatible"
        fi
    fi

    # Check if update needed
    if is_update_available "$installed_version" "$available_version"; then
        log_info "Update available: $installed_version -> $available_version"
        install_update "$bundle_url" "$available_version"
    else
        log_info "System is up to date"
    fi

    record_check
    log_info "OTA update check complete"
}

main "$@"
