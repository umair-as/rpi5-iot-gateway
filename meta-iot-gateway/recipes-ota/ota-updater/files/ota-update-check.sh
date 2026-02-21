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
readonly LOCK_FILE="${OTA_LOCK_FILE:-${STATE_DIR}/ota-updater.lock}"

# Logging helpers (all to stderr so stdout stays clean for data)
log_info()  { echo "[$(date -Iseconds)] [INFO]  $*" >&2; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $*" >&2; }
die()       { log_error "$*"; exit 1; }

on_err() { log_error "failed at line ${1:-?} (cmd: ${BASH_COMMAND:-sh})"; }
trap 'on_err $LINENO' ERR

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
        CA_CERT=$(jq -r '.ca_cert // "/etc/ota/ca.crt"' "$CONFIG_FILE")
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
    local curl_opts=(
        --silent
        --show-error
        --fail
        --connect-timeout "${CONNECT_TIMEOUT:-30}"
        --max-time "${MAX_TIME:-300}"
    )

    # Add mTLS options if certs are configured
    if [[ -f "${DEVICE_CERT:-}" && -f "${DEVICE_KEY:-}" ]]; then
        curl_opts+=(--cert "$DEVICE_CERT" --key "$DEVICE_KEY")
        log_info "Using device certificate: $DEVICE_CERT"
    fi

    if [[ -f "${CA_CERT:-}" ]]; then
        curl_opts+=(--cacert "$CA_CERT")
    fi

    log_info "Fetching manifest from: $manifest_url"
    curl "${curl_opts[@]}" "$manifest_url"
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

    log_info "Installing update: version=$version url=$bundle_url"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would execute: rauc install '$bundle_url'"
        return 0
    fi

    # RAUC handles download, verification, and installation
    if rauc install "$bundle_url"; then
        log_info "Update installed successfully. Reboot required."
        # Record successful update
        echo "{\"version\":\"$version\",\"timestamp\":\"$(date -Iseconds)\",\"status\":\"installed\"}" \
            > "${STATE_DIR}/last-update"
        return 0
    else
        log_error "RAUC installation failed"
        return 1
    fi
}

# Record check timestamp
record_check() {
    mkdir -p "$STATE_DIR"
    echo "{\"timestamp\":\"$(date -Iseconds)\",\"server\":\"$SERVER_URL\"}" > "$STATE_FILE"
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

    # Parse manifest
    local available_version bundle_url compatible
    available_version=$(echo "$manifest" | jq -r '.version // empty')
    bundle_url=$(echo "$manifest" | jq -r '.bundle_url // empty')
    compatible=$(echo "$manifest" | jq -r '.compatible // empty')

    if [[ -z "$available_version" || -z "$bundle_url" ]]; then
        die "Invalid manifest: missing version or bundle_url"
    fi

    log_info "Available version: $available_version"

    # Check compatibility if specified in manifest
    if [[ -n "$compatible" ]]; then
        local system_compatible
        system_compatible=$(rauc status --output-format=json | jq -r '.compatible // empty')
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
