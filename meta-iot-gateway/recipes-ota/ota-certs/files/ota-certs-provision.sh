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
readonly ALLOW_KEYLESS_DEVICE_CERTS="${OTA_CERTS_ALLOW_KEYLESS_DEVICE_CERTS:-0}"
readonly REQUIRE_PKCS11_PIN="${OTA_CERTS_REQUIRE_PKCS11_PIN:-0}"
readonly PKCS11_PIN_FILE="${CERT_DIR}/pkcs11-pin"
readonly PKCS11_MODULE="${OTA_CERTS_PKCS11_MODULE:-/usr/lib/pkcs11/libtpm2_pkcs11.so}"
readonly PKCS11_STORE="${OTA_CERTS_PKCS11_STORE:-/var/lib/tpm2_pkcs11}"
readonly PKCS11_TOKEN_LABEL="${OTA_CERTS_PKCS11_TOKEN_LABEL:-iotgw}"
readonly PKCS11_KEY_LABEL="${OTA_CERTS_PKCS11_KEY_LABEL:-rauc-client-key}"

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

normalize_pkcs11_pin_file() {
    local path="$1"
    local pin=""
    [ -f "$path" ] || return 0
    pin="$(head -n 1 "$path" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -z "$pin" ]]; then
        return 1
    fi
    printf '%s' "$pin" > "$path"
    return 0
}

pkcs11_pin_read() {
    [ -r "$PKCS11_PIN_FILE" ] || return 1
    head -n 1 "$PKCS11_PIN_FILE" | tr -d '\r\n'
}

pkcs11_preflight_check() {
    local pin=""
    local msg_file="/tmp/ota-certs-pkcs11-msg.bin"
    local sig_file="/tmp/ota-certs-pkcs11-sig.bin"
    local su_cmd=""

    if [[ "$REQUIRE_PKCS11_PIN" != "1" ]]; then
        return 0
    fi

    if ! command -v pkcs11-tool >/dev/null 2>&1; then
        log_error "PKCS#11 preflight failed: pkcs11-tool not found"
        return 1
    fi
    if ! id ota >/dev/null 2>&1; then
        log_error "PKCS#11 preflight failed: ota user not found"
        return 1
    fi
    if [ ! -r "$PKCS11_MODULE" ]; then
        log_error "PKCS#11 preflight failed: module missing (${PKCS11_MODULE})"
        return 1
    fi

    pin="$(pkcs11_pin_read || true)"
    if [[ -z "$pin" ]]; then
        log_error "PKCS#11 preflight failed: missing or empty ${PKCS11_PIN_FILE}"
        return 1
    fi

    printf 'ota-pkcs11-preflight\n' > "$msg_file"
    su_cmd="TPM2_PKCS11_STORE=${PKCS11_STORE} pkcs11-tool --module ${PKCS11_MODULE} --token-label ${PKCS11_TOKEN_LABEL} --login --pin '${pin}' --label ${PKCS11_KEY_LABEL} --sign --mechanism RSA-PKCS --input-file ${msg_file} --output-file ${sig_file}"
    if ! su -s /bin/sh ota -c "$su_cmd" >/dev/null 2>&1; then
        log_error "PKCS#11 preflight failed: unable to sign with token='${PKCS11_TOKEN_LABEL}' key='${PKCS11_KEY_LABEL}' as ota user"
        rm -f "$msg_file" "$sig_file"
        return 1
    fi
    rm -f "$msg_file" "$sig_file"

    log_info "PKCS#11 preflight passed for token='${PKCS11_TOKEN_LABEL}' key='${PKCS11_KEY_LABEL}'"
    return 0
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

# Check if valid certs exist in an arbitrary directory.
# This validates identity material only (CA chain + expiry + key presence).
# PKCS#11 readiness is a transport concern checked separately.
certs_valid_in_dir() {
    local dir="$1"
    [[ -f "$dir/device.crt" ]] || return 1
    [[ -f "$dir/ca.crt" ]] || return 1
    if [[ "$ALLOW_KEYLESS_DEVICE_CERTS" != "1" ]]; then
        [[ -f "$dir/device.key" ]] || return 1
    fi

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
    if [[ -f "$PKCS11_PIN_FILE" ]]; then
        chown root:ota "$PKCS11_PIN_FILE" 2>/dev/null || true
        chmod 0640 "$PKCS11_PIN_FILE"
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
    [[ "$src_ca_fp" == "$dst_ca_fp" && "$src_dev_fp" == "$dst_dev_fp" ]] || return 1

    if [[ "$REQUIRE_PKCS11_PIN" == "1" && -f "$src/pkcs11-pin" && -f "$PKCS11_PIN_FILE" ]]; then
        local src_pin=""
        local dst_pin=""
        src_pin="$(head -n 1 "$src/pkcs11-pin" 2>/dev/null | tr -d '\r\n' || true)"
        dst_pin="$(head -n 1 "$PKCS11_PIN_FILE" 2>/dev/null | tr -d '\r\n' || true)"
        [[ -n "$src_pin" && -n "$dst_pin" && "$src_pin" == "$dst_pin" ]] || return 1
    fi
    return 0
}

backup_certs_to_data() {
    mkdir -p "$DATA_SRC"
    install -m 0644 "$CERT_DIR/ca.crt" "$DATA_SRC/ca.crt"
    install -m 0644 "$CERT_DIR/device.crt" "$DATA_SRC/device.crt"
    if [[ -f "$CERT_DIR/device.key" ]]; then
        install -m 0640 "$CERT_DIR/device.key" "$DATA_SRC/device.key"
    fi
    if [[ -f "$PKCS11_PIN_FILE" ]]; then
        install -m 0640 "$PKCS11_PIN_FILE" "$DATA_SRC/pkcs11-pin"
        normalize_pkcs11_pin_file "$DATA_SRC/pkcs11-pin" || {
            log_error "Invalid PKCS#11 PIN content in ${PKCS11_PIN_FILE}"
            return 1
        }
    fi
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

    if [[ -f "$src/device.crt" && -f "$src/ca.crt" ]] && [[ -f "$src/device.key" || "$ALLOW_KEYLESS_DEVICE_CERTS" == "1" ]]; then
        log_info "Provisioning certificates from $desc"

        install -m 0644 "$src/ca.crt" "$CERT_DIR/ca.crt"
        install -m 0644 "$src/device.crt" "$CERT_DIR/device.crt"
        if [[ -f "$src/device.key" ]]; then
            install -m 0640 "$src/device.key" "$CERT_DIR/device.key"
        elif [[ "$ALLOW_KEYLESS_DEVICE_CERTS" == "1" ]]; then
            log_info "Source has no device.key; keyless mode is enabled"
        fi
        if [[ -f "$src/pkcs11-pin" ]]; then
            install -m 0640 "$src/pkcs11-pin" "$PKCS11_PIN_FILE"
            normalize_pkcs11_pin_file "$PKCS11_PIN_FILE" || {
                log_error "Invalid PKCS#11 PIN content in source ${src}/pkcs11-pin"
                return 1
            }
        fi

        # Set ownership for ota user
        if [[ -f "$CERT_DIR/device.key" ]]; then
            chown root:ota "$CERT_DIR/device.key" 2>/dev/null || true
        fi
        if [[ -f "$PKCS11_PIN_FILE" ]]; then
            chown root:ota "$PKCS11_PIN_FILE" 2>/dev/null || true
        fi
        chown root:ota "$CERT_DIR/device.crt" 2>/dev/null || true
        chown root:ota "$CERT_DIR/ca.crt" 2>/dev/null || true
        chmod 0750 "$CERT_DIR"
        if [[ -f "$CERT_DIR/device.key" ]]; then
            chmod 0640 "$CERT_DIR/device.key"
        fi
        if [[ -f "$PKCS11_PIN_FILE" ]]; then
            chmod 0640 "$PKCS11_PIN_FILE"
        fi
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
    if [[ "$ALLOW_KEYLESS_DEVICE_CERTS" == "1" ]]; then
        log_info "Keyless device-certificate mode enabled (TPM key expected at runtime)"
    fi
    if [[ "$REQUIRE_PKCS11_PIN" == "1" ]]; then
        log_info "PKCS#11 PIN mode enabled (expects ${PKCS11_PIN_FILE})"
    fi

    # Create cert directory
    install -d -m 0750 "$CERT_DIR"
    chown root:ota "$CERT_DIR" 2>/dev/null || true

    if ! getent group ota >/dev/null 2>&1; then
        log_error "Required group 'ota' is missing"
        exit 1
    fi

    # Normalize ownership/modes first, especially for baked-in certs.
    ensure_cert_permissions
    if [[ "$REQUIRE_PKCS11_PIN" == "1" ]] && [[ -f "$PKCS11_PIN_FILE" ]]; then
        if ! normalize_pkcs11_pin_file "$PKCS11_PIN_FILE"; then
            log_error "Invalid PKCS#11 PIN content in ${PKCS11_PIN_FILE}"
            exit 1
        fi
    fi

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
        if ! pkcs11_preflight_check; then
            log_warn "──────────────────────────────────────────────────────"
            log_warn "TPM PKCS#11 preflight failed — running in degraded mode."
            log_warn "File-based certificates are valid and OTA will work,"
            log_warn "but RAUC streaming requires a provisioned TPM token."
            log_warn ""
            log_warn "To bootstrap the TPM PKCS#11 store, run on the host:"
            log_warn "  ./scripts/ota-pkcs11-provision-check.sh"
            log_warn "then follow the provisioning steps printed on target."
            log_warn "──────────────────────────────────────────────────────"
        fi
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
