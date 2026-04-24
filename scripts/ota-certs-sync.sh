#!/usr/bin/env bash
set -euo pipefail

# Sync OTA certificate material to target and trigger provisioning.
#
# Default behavior:
# - Reuse existing device-filekey.{key,crt} in CA dir when present.
# - Generate missing key/csr/crt signed by local CA.
# - Upload ca.crt + device.{crt,key} to /data/ota/certs on target.
# - Restart ota-certs-provision and print verification details.

TARGET="${TARGET:-iotgw}"
CA_DIR="${CA_DIR:-$HOME/rauc-keys/ota-dev-ca}"
DEVICE_BASENAME="${DEVICE_BASENAME:-device-filekey}"
DAYS="${DAYS:-3650}"

# DN defaults requested for project consistency.
CERT_COUNTRY="${CERT_COUNTRY:-DE}"
CERT_STATE="${CERT_STATE:-NRW}"
CERT_CITY="${CERT_CITY:-Leverkusen}"
CERT_ORG="${CERT_ORG:-IoT Gateway}"
CERT_OU="${CERT_OU:-OTA}"
CERT_CN="${CERT_CN:-iot-gateway}"

FORCE_REGEN=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --target HOST            SSH target (default: ${TARGET})
  --ca-dir DIR             CA directory (default: ${CA_DIR})
  --device-basename NAME   Device cert/key basename (default: ${DEVICE_BASENAME})
  --force-regen            Regenerate device key/csr/crt even if present
  -h, --help               Show this help

Environment overrides:
  TARGET, CA_DIR, DEVICE_BASENAME, DAYS
  CERT_COUNTRY, CERT_STATE, CERT_CITY, CERT_ORG, CERT_OU, CERT_CN
EOF
}

log() { printf '[ota-certs-sync] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

key_matches_cert() {
    local key_file="$1"
    local cert_file="$2"
    local key_pub cert_pub

    key_pub="$(openssl pkey -in "${key_file}" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    cert_pub="$(openssl x509 -in "${cert_file}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [ -n "${key_pub}" ] && [ -n "${cert_pub}" ] && [ "${key_pub}" = "${cert_pub}" ]
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target)
                shift; [ "${1:-}" ] || die "--target requires value"
                TARGET="$1"
                ;;
            --ca-dir)
                shift; [ "${1:-}" ] || die "--ca-dir requires value"
                CA_DIR="$1"
                ;;
            --device-basename)
                shift; [ "${1:-}" ] || die "--device-basename requires value"
                DEVICE_BASENAME="$1"
                ;;
            --force-regen)
                FORCE_REGEN=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    need_cmd openssl
    need_cmd ssh
    need_cmd scp

    local ca_crt="${CA_DIR}/ca.crt"
    local ca_key="${CA_DIR}/ca.key"
    local dev_key="${CA_DIR}/${DEVICE_BASENAME}.key"
    local dev_csr="${CA_DIR}/${DEVICE_BASENAME}.csr"
    local dev_crt="${CA_DIR}/${DEVICE_BASENAME}.crt"
    local subject="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}/CN=${CERT_CN}"

    [ -f "${ca_crt}" ] || die "missing CA cert: ${ca_crt}"
    [ -f "${ca_key}" ] || die "missing CA key: ${ca_key}"
    mkdir -p "${CA_DIR}"

    local regen_cert=0

    if [ "${FORCE_REGEN}" -eq 1 ]; then
        log "force regen enabled; removing existing ${DEVICE_BASENAME}.{key,csr,crt}"
        rm -f "${dev_key}" "${dev_csr}" "${dev_crt}"
    fi

    if [ ! -f "${dev_key}" ]; then
        log "generating ${dev_key}"
        openssl genrsa -out "${dev_key}" 2048 >/dev/null 2>&1
        regen_cert=1
    else
        log "reusing existing key: ${dev_key}"
    fi

    if [ -f "${dev_crt}" ] && ! key_matches_cert "${dev_key}" "${dev_crt}"; then
        log "existing cert does not match key; regenerating ${dev_crt}"
        rm -f "${dev_crt}" "${dev_csr}"
        regen_cert=1
    fi

    if [ ! -f "${dev_crt}" ] || [ "${regen_cert}" -eq 1 ]; then
        log "generating CSR: ${dev_csr}"
        openssl req -new -key "${dev_key}" -subj "${subject}" -out "${dev_csr}" >/dev/null 2>&1

        log "signing certificate: ${dev_crt}"
        openssl x509 -req \
            -in "${dev_csr}" \
            -CA "${ca_crt}" \
            -CAkey "${ca_key}" \
            -CAcreateserial \
            -out "${dev_crt}" \
            -days "${DAYS}" \
            -sha256 >/dev/null 2>&1
    else
        log "reusing existing cert: ${dev_crt}"
    fi

    log "verifying device cert chain"
    openssl verify -CAfile "${ca_crt}" "${dev_crt}" >/dev/null

    log "preparing target path /data/ota/certs on ${TARGET}"
    ssh "${TARGET}" "mkdir -p /data/ota/certs"

    log "uploading cert material"
    scp "${ca_crt}" "${TARGET}:/data/ota/certs/ca.crt"
    scp "${dev_crt}" "${TARGET}:/data/ota/certs/device.crt"
    scp "${dev_key}" "${TARGET}:/data/ota/certs/device.key"

    log "triggering ota-certs-provision and verifying target files"
    ssh "${TARGET}" "\
        systemctl restart ota-certs-provision && \
        ls -l /etc/ota && \
        openssl verify -CAfile /etc/ota/ca.crt /etc/ota/device.crt"

    log "done"
    log "target=${TARGET}"
    log "ca=${ca_crt}"
    log "device_cert=${dev_crt}"
    log "device_key=${dev_key}"
}

main "$@"
