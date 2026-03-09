#!/bin/bash
# SPDX-License-Identifier: MIT
#
# ota-certs-provision: Provision mTLS certificates for OTA updates
#
# Certificate sources (in priority order):
# 1. /boot/iotgw/ota/ - Per-device certs from SD card (production)
# 2. /data/ota/certs/ - Previously provisioned certs (persistent)
# 3. Existing /etc/ota/   - Keep current valid material
#

set -euo pipefail

readonly CERT_DIR="/etc/ota"
readonly BOOT_SRC="/boot/iotgw/ota"
readonly BOOT_META="${BOOT_SRC}/meta.json"
readonly DATA_SRC="/data/ota/certs"
readonly STATE_FILE="/var/lib/ota-certs-provision.state"

get_device_id() {
    local mid=""
    local mac=""

    if [[ -s /etc/machine-id ]]; then
        mid=$(head -c 8 /etc/machine-id 2>/dev/null || true)
    fi
    if [[ -z "${mid}" && -s /run/machine-id ]]; then
        mid=$(head -c 8 /run/machine-id 2>/dev/null || true)
    fi
    if [[ -n "${mid}" ]]; then
        printf '%s' "${mid}"
        return 0
    fi

    mac=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | head -c 8 || true)
    if [[ -n "${mac}" ]]; then
        printf '%s' "${mac}"
        return 0
    fi

    printf 'unknown'
    return 0
}
readonly STAMP="/var/lib/ota-certs-provision.done"

log_info()  { echo "[$(date -Iseconds)] [INFO]  $*"; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] [ERROR] $*" >&2; }

cert_chain_valid() {
    openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/device.crt" >/dev/null 2>&1
}

state_get() {
    local key="$1"
    [ -r "$STATE_FILE" ] || return 1
    sed -nE "s/^${key}=(.*)$/\\1/p" "$STATE_FILE" | tail -n 1
}

boot_meta_get_provision_id() {
    [ -r "$BOOT_META" ] || return 1
    sed -nE 's/.*"provision_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$BOOT_META" | head -n 1
}

# Check if valid certs exist in an arbitrary directory
certs_valid_in_dir() {
    local dir="$1"
    [[ -f "$dir/device.crt" ]] && \
    [[ -f "$dir/device.key" ]] && \
    [[ -f "$dir/ca.crt" ]] && \
    openssl x509 -in "$dir/device.crt" -noout -checkend 86400 2>/dev/null && \
    openssl verify -CAfile "$dir/ca.crt" "$dir/device.crt" >/dev/null 2>&1
}

# Check if valid certs already exist
certs_valid() {
    certs_valid_in_dir "$CERT_DIR"
}

cert_fingerprint() {
    local cert="$1"
    openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//;s/://g'
}

ensure_cert_permissions() {
    local f
    for f in "$CERT_DIR/ca.crt" "$CERT_DIR/device.crt"; do
        [[ -f "$f" ]] || continue
        chown root:ota "$f" 2>/dev/null || true
        chmod 0644 "$f"
    done
    if [[ -f "$CERT_DIR/device.key" ]]; then
        chown root:ota "$CERT_DIR/device.key" 2>/dev/null || true
        chmod 0640 "$CERT_DIR/device.key"
    fi
}

same_cert_material() {
    local src="$1"
    local src_ca_fp=""
    local src_dev_fp=""
    local dst_ca_fp=""
    local dst_dev_fp=""

    [[ -f "$src/ca.crt" && -f "$src/device.crt" ]] || return 1
    [[ -f "$CERT_DIR/ca.crt" && -f "$CERT_DIR/device.crt" ]] || return 1

    src_ca_fp=$(cert_fingerprint "$src/ca.crt")
    src_dev_fp=$(cert_fingerprint "$src/device.crt")
    dst_ca_fp=$(cert_fingerprint "$CERT_DIR/ca.crt")
    dst_dev_fp=$(cert_fingerprint "$CERT_DIR/device.crt")

    [[ -n "$src_ca_fp" && -n "$src_dev_fp" && -n "$dst_ca_fp" && -n "$dst_dev_fp" ]] || return 1
    [[ "$src_ca_fp" == "$dst_ca_fp" && "$src_dev_fp" == "$dst_dev_fp" ]]
}

backup_certs_to_data() {
    mkdir -p "$DATA_SRC"
    install -m 0644 "$CERT_DIR/ca.crt" "$DATA_SRC/ca.crt"
    install -m 0644 "$CERT_DIR/device.crt" "$DATA_SRC/device.crt"
    install -m 0640 "$CERT_DIR/device.key" "$DATA_SRC/device.key"
}

write_state() {
    local source="$1"
    local provision_id="${2:-}"
    local ca_fp=""
    local dev_fp=""
    local expiry=""
    ca_fp=$(cert_fingerprint "$CERT_DIR/ca.crt" || true)
    dev_fp=$(cert_fingerprint "$CERT_DIR/device.crt" || true)
    expiry=$(openssl x509 -in "$CERT_DIR/device.crt" -noout -enddate 2>/dev/null | sed 's/.*=//' || true)
    cat > "$STATE_FILE" <<EOF
updated_at=$(date -Iseconds)
status=applied
source=${source}
provision_id=${provision_id}
ca_sha256=${ca_fp}
device_sha256=${dev_fp}
device_expiry=${expiry}
EOF
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

main() {
    log_info "OTA certificate provisioning starting"

    # Create cert directory
    install -d -m 0750 "$CERT_DIR"
    chown root:ota "$CERT_DIR" 2>/dev/null || true

    if ! getent group ota >/dev/null 2>&1; then
        log_error "Required group 'ota' is missing"
        exit 1
    fi

    # Normalize ownership/modes first, especially for baked-in certs.
    ensure_cert_permissions

    # Try sources in priority order
    local provisioned=0
    local source_used="none"
    local desired_src=""
    local source_provision_id=""
    local previous_provision_id=""
    local previous_status=""
    local boot_provision_id=""

    # 1. Check boot partition (per-device production certs)
    if [[ -d "$BOOT_SRC" ]] && certs_valid_in_dir "$BOOT_SRC"; then
        previous_provision_id="$(state_get provision_id || true)"
        previous_status="$(state_get status || true)"
        boot_provision_id="$(boot_meta_get_provision_id || true)"
        if [[ -r "$BOOT_META" && -z "$boot_provision_id" ]]; then
            log_error "Boot certificate metadata exists but provision_id is missing/invalid: $BOOT_META"
            exit 1
        fi
        if [[ -n "$boot_provision_id" && "$boot_provision_id" == "$previous_provision_id" && "$previous_status" == "applied" ]]; then
            if certs_valid && same_cert_material "$BOOT_SRC"; then
                provisioned=1
                source_used="existing"
                source_provision_id="$boot_provision_id"
                log_info "Boot source provision_id already applied; keeping current certificate material"
            else
                log_error "Boot source provision_id already applied but certificate material differs; refusing stale/replayed import"
                exit 1
            fi
        elif [[ -n "$boot_provision_id" && "$boot_provision_id" == "$previous_provision_id" ]]; then
            log_warn "Boot source provision_id matches previous state but previous status is not 'applied'; allowing retry import"
            desired_src="$BOOT_SRC"
            source_used="boot"
            source_provision_id="$boot_provision_id"
        else
            desired_src="$BOOT_SRC"
            source_used="boot"
            source_provision_id="$boot_provision_id"
            log_info "Valid certificates found in boot source"
            if [[ -n "$boot_provision_id" ]]; then
                log_info "Boot source provision_id=$boot_provision_id"
            fi
        fi
    # 2. Check persistent data partition
    elif [[ -d "$DATA_SRC" ]] && certs_valid_in_dir "$DATA_SRC"; then
        desired_src="$DATA_SRC"
        source_used="data"
        log_info "Valid certificates found in data source"
    fi

    if [[ -n "$desired_src" ]]; then
        if certs_valid && same_cert_material "$desired_src"; then
            provisioned=1
            log_info "Certificate material already aligned with ${source_used} source"
        elif copy_certs "$desired_src" "${source_used} source ($desired_src)"; then
            provisioned=1
            log_info "Certificates provisioned from ${source_used} source"
        fi
    fi

    # 3. Keep current certs if still valid and no higher-priority source exists.
    if [[ $provisioned -eq 0 ]] && certs_valid; then
        provisioned=1
        source_used="existing"
        source_provision_id="$(state_get provision_id || true)"
        log_info "Valid certificates already present in $CERT_DIR; keeping current material"
    fi

    if [[ $provisioned -eq 0 ]]; then
        log_error "No valid OTA certificate source found in ${BOOT_SRC}, ${DATA_SRC}, or existing ${CERT_DIR}"
        exit 1
    fi

    # Verify certificates
    if certs_valid; then
        log_info "Certificate verification passed"
        backup_certs_to_data
        write_state "$source_used" "$source_provision_id"
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
