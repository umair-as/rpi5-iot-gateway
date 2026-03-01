#!/bin/bash
# SPDX-License-Identifier: MIT
#
# ota-certs-provision: Provision mTLS certificates for OTA updates
#
# Certificate sources (in priority order):
# 1. /boot/iotgw/ota/ - Per-device certs from SD card (production)
# 2. /data/ota/certs/ - Previously provisioned certs (persistent)
# 3. Generate dev certs - For development/testing only
#

set -euo pipefail

readonly CERT_DIR="/etc/ota"
readonly BOOT_SRC="/boot/iotgw/ota"
readonly DATA_SRC="/data/ota/certs"
readonly DEV_CA_DIR_DEFAULT="/data/ota/dev-ca"
readonly DEV_CA_SERIAL="/data/ota/dev-ca/dev-ca.srl"
readonly STAMP="/var/lib/ota-certs-provision.done"

log_info()  { echo "[$(date -Iseconds)] [INFO]  $*"; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $*" >&2; }

resolve_dev_ca_files() {
    local src_dir="$1"
    if [[ -f "$src_dir/dev-ca.crt" && -f "$src_dir/dev-ca.key" ]]; then
        echo "$src_dir/dev-ca.crt|$src_dir/dev-ca.key"
        return 0
    fi
    if [[ -f "$src_dir/ca.crt" && -f "$src_dir/ca.key" ]]; then
        echo "$src_dir/ca.crt|$src_dir/ca.key"
        return 0
    fi
    return 1
}

cert_chain_valid() {
    openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/device.crt" >/dev/null 2>&1
}

# Check if valid certs already exist
certs_valid() {
    [[ -f "$CERT_DIR/device.crt" ]] && \
    [[ -f "$CERT_DIR/device.key" ]] && \
    [[ -f "$CERT_DIR/ca.crt" ]] && \
    openssl x509 -in "$CERT_DIR/device.crt" -noout -checkend 86400 2>/dev/null && \
    cert_chain_valid
}

# Copy certs from source directory
copy_certs() {
    local src="$1"
    local desc="$2"

    if [[ -f "$src/device.crt" && -f "$src/device.key" && -f "$src/ca.crt" ]]; then
        log_info "Provisioning certificates from $desc"

        install -m 0644 "$src/ca.crt" "$CERT_DIR/ca.crt"
        install -m 0644 "$src/device.crt" "$CERT_DIR/device.crt"
        install -m 0640 "$src/device.key" "$CERT_DIR/device.key"

        # Set ownership for ota user
        chown root:ota "$CERT_DIR/device.key" 2>/dev/null || true
        chown root:ota "$CERT_DIR/device.crt" 2>/dev/null || true
        chown root:ota "$CERT_DIR/ca.crt" 2>/dev/null || true
        chmod 0750 "$CERT_DIR"
        chmod 0640 "$CERT_DIR/device.key"
        chmod 0644 "$CERT_DIR/device.crt" "$CERT_DIR/ca.crt"
        if ! cert_chain_valid; then
            log_error "Provisioned certificates from $desc do not chain to $CERT_DIR/ca.crt"
            return 1
        fi
        return 0
    fi
    return 1
}

# Generate development certificates
ensure_dev_ca() {
    local src_dir="$1"
    local external="$2"
    local ca_pair=""

    if ca_pair=$(resolve_dev_ca_files "$src_dir"); then
        return 0
    fi

    if [[ "$external" -eq 1 ]]; then
        log_error "Development CA missing in $src_dir (set RAUC_OTA_CA_DIR/IOTGW_OTA_CA_DIR correctly)"
        return 1
    fi

    log_warn "No development CA found; generating a local dev CA in $src_dir"
    mkdir -p "$src_dir"
    chmod 0700 "$src_dir"

    if ! openssl genrsa -out "$src_dir/dev-ca.key" 2048 2>/dev/null; then
        log_error "Failed to generate dev CA key"
        return 1
    fi

    if ! openssl req -x509 -new -nodes \
        -key "$src_dir/dev-ca.key" \
        -sha256 -days 3650 \
        -subj "/CN=iotgw-dev-ca/O=IoT Gateway/OU=OTA" \
        -out "$src_dir/dev-ca.crt" 2>/dev/null; then
        log_error "Failed to generate dev CA certificate"
        return 1
    fi

    chmod 0600 "$src_dir/dev-ca.key"
    chmod 0644 "$src_dir/dev-ca.crt"
    return 0
}

generate_dev_certs() {
    log_warn "Generating DEVELOPMENT certificates - DO NOT use in production!"

    local configured_ca_dir="${RAUC_OTA_CA_DIR:-${IOTGW_OTA_CA_DIR:-}}"
    local dev_ca_dir="${configured_ca_dir:-$DEV_CA_DIR_DEFAULT}"
    local external_ca=0
    if [[ -n "${configured_ca_dir}" ]]; then
        external_ca=1
    fi
    local ca_crt=""
    local ca_key=""
    local ca_pair=""

    if ! ensure_dev_ca "$dev_ca_dir" "$external_ca"; then
        return 1
    fi
    if ! ca_pair=$(resolve_dev_ca_files "$dev_ca_dir"); then
        log_error "Failed to resolve CA pair in $dev_ca_dir"
        return 1
    fi
    ca_crt="${ca_pair%%|*}"
    ca_key="${ca_pair##*|}"

    # Get a unique device ID (prefer machine-id, fallback to MAC)
    local device_id
    if [[ -f /etc/machine-id ]]; then
        device_id=$(head -c 8 /etc/machine-id)
    else
        device_id=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | head -c 8 || echo "unknown")
    fi

    log_info "Generating cert for device: $device_id"

    # Generate device private key and certs in temp paths, then move into place.
    local tmp_key
    local tmp_csr
    local tmp_crt
    tmp_key=$(mktemp /tmp/ota-device.key.XXXXXX)
    tmp_csr=$(mktemp /tmp/ota-device.csr.XXXXXX)
    tmp_crt=$(mktemp /tmp/ota-device.crt.XXXXXX)

    if ! openssl genrsa -out "${tmp_key}" 2048 2>/dev/null; then
        log_error "Failed to generate device private key"
        rm -f "${tmp_key}" "${tmp_csr}" "${tmp_crt}"
        return 1
    fi

    if ! openssl req -new \
        -key "${tmp_key}" \
        -out "${tmp_csr}" \
        -subj "/CN=iot-device-${device_id}/O=Development/OU=OTA"; then
        log_error "Failed to generate device CSR"
        rm -f "${tmp_key}" "${tmp_csr}" "${tmp_crt}"
        return 1
    fi

    mkdir -p "$DATA_SRC"

    if ! openssl x509 -req \
        -in "${tmp_csr}" \
        -CA "${ca_crt}" \
        -CAkey "${ca_key}" \
        -CAserial "${DEV_CA_SERIAL}" \
        -CAcreateserial \
        -out "${tmp_crt}" \
        -days 365 \
        -sha256; then
        log_error "Failed to sign device certificate with dev CA"
        rm -f "${tmp_key}" "${tmp_csr}" "${tmp_crt}"
        return 1
    fi

    if [[ ! -s "${tmp_crt}" ]]; then
        log_error "Generated device certificate is empty"
        rm -f "${tmp_key}" "${tmp_csr}" "${tmp_crt}"
        return 1
    fi

    install -m 0640 "${tmp_key}" "$CERT_DIR/device.key"
    install -m 0644 "${tmp_crt}" "$CERT_DIR/device.crt"

    # Copy CA cert
    install -m 0644 "${ca_crt}" "$CERT_DIR/ca.crt"

    # Set permissions
    chmod 0750 "$CERT_DIR"
    chmod 0644 "$CERT_DIR/device.crt"
    chmod 0640 "$CERT_DIR/device.key"
    chown root:ota "$CERT_DIR/device.key" 2>/dev/null || true
    chown root:ota "$CERT_DIR/device.crt" 2>/dev/null || true
    chown root:ota "$CERT_DIR/ca.crt" 2>/dev/null || true
    # Cleanup
    rm -f "${tmp_key}" "${tmp_csr}" "${tmp_crt}"

    # Backup to persistent storage
    mkdir -p "$DATA_SRC"
    cp "$CERT_DIR/device.crt" "$DATA_SRC/"
    cp "$CERT_DIR/device.key" "$DATA_SRC/"
    cp "$CERT_DIR/ca.crt" "$DATA_SRC/"
    chmod 0640 "$DATA_SRC/device.key"
    if ! cert_chain_valid; then
        log_error "Generated development certificate does not chain to $CERT_DIR/ca.crt"
        return 1
    fi

    log_info "Development certificates generated and backed up to $DATA_SRC"
    return 0
}

main() {
    log_info "OTA certificate provisioning starting"

    # Create cert directory
    install -d -m 0750 "$CERT_DIR"
    chown root:ota "$CERT_DIR" 2>/dev/null || true

    if ! getent group ota >/dev/null 2>&1; then
        log_error "Required group 'ota' is missing"
        exit 1
    fi

    # Check if already provisioned with valid certs
    if [[ -f "$STAMP" ]] && certs_valid; then
        log_info "Valid certificates already provisioned"
        exit 0
    fi

    # Try sources in priority order
    local provisioned=0

    # 1. Check boot partition (per-device production certs)
    if [[ -d "$BOOT_SRC" ]] && copy_certs "$BOOT_SRC" "boot partition ($BOOT_SRC)"; then
        provisioned=1
        log_info "Production certificates provisioned from SD card"
    fi

    # 2. Check persistent data partition
    if [[ $provisioned -eq 0 && -d "$DATA_SRC" ]] && copy_certs "$DATA_SRC" "data partition ($DATA_SRC)"; then
        provisioned=1
        log_info "Certificates restored from persistent storage"
    fi

    # 3. Generate development certs as fallback
    if [[ $provisioned -eq 0 ]]; then
        if generate_dev_certs; then
            provisioned=1
        else
            log_error "Failed to provision certificates"
            exit 1
        fi
    fi

    # Verify certificates
    if certs_valid; then
        log_info "Certificate verification passed"
        touch "$STAMP"
    else
        log_error "Certificate verification failed"
        exit 1
    fi

    # Log certificate info
    log_info "Certificate CN: $(openssl x509 -in "$CERT_DIR/device.crt" -noout -subject 2>/dev/null | sed 's/.*CN = //')"
    log_info "Certificate expiry: $(openssl x509 -in "$CERT_DIR/device.crt" -noout -enddate 2>/dev/null | sed 's/.*=//')"

    log_info "OTA certificate provisioning complete"
}

main "$@"
