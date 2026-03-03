#!/bin/bash
# SPDX-License-Identifier: MIT
#
# generate-dev-cert.sh: Manually generate a development device certificate
#
# Usage: ota-generate-dev-cert [device-id]
#

set -euo pipefail

readonly DEV_CA_DIR_DEFAULT="/data/ota/dev-ca"
readonly CERT_DIR="/etc/ota"

detect_device_id() {
    local mid=""
    if [[ -s /etc/machine-id ]]; then
        mid="$(head -c 8 /etc/machine-id 2>/dev/null || true)"
    fi
    if [[ -z "${mid}" && -s /run/machine-id ]]; then
        mid="$(head -c 8 /run/machine-id 2>/dev/null || true)"
    fi
    if [[ -z "${mid}" ]]; then
        mid="dev-device"
    fi
    printf '%s' "${mid}"
}

device_id="${1:-$(detect_device_id)}"

echo "Generating development certificate for device: $device_id"

DEV_CA_DIR="${RAUC_OTA_CA_DIR:-${IOTGW_OTA_CA_DIR:-$DEV_CA_DIR_DEFAULT}}"
if [[ -f "$DEV_CA_DIR/dev-ca.crt" && -f "$DEV_CA_DIR/dev-ca.key" ]]; then
    CA_CRT="$DEV_CA_DIR/dev-ca.crt"
    CA_KEY="$DEV_CA_DIR/dev-ca.key"
elif [[ -f "$DEV_CA_DIR/ca.crt" && -f "$DEV_CA_DIR/ca.key" ]]; then
    CA_CRT="$DEV_CA_DIR/ca.crt"
    CA_KEY="$DEV_CA_DIR/ca.key"
else
    echo "ERROR: Development CA not found in $DEV_CA_DIR" >&2
    echo "Set RAUC_OTA_CA_DIR/IOTGW_OTA_CA_DIR or run ota-certs-provision to generate a local dev CA." >&2
    exit 1
fi

mkdir -p "$CERT_DIR"

# Generate key
openssl genrsa -out "$CERT_DIR/device.key" 2048 2>/dev/null

# Generate CSR and sign
openssl req -new \
    -key "$CERT_DIR/device.key" \
    -subj "/CN=iot-device-${device_id}/O=Development/OU=OTA" \
    | openssl x509 -req \
        -CA "$CA_CRT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$CERT_DIR/device.crt" \
        -days 365 \
        -sha256 2>/dev/null

# Copy CA
cp "$CA_CRT" "$CERT_DIR/ca.crt"

# Set permissions
chmod 0644 "$CERT_DIR/device.crt" "$CERT_DIR/ca.crt"
chmod 0640 "$CERT_DIR/device.key"
chown root:ota "$CERT_DIR"/*.crt "$CERT_DIR"/*.key 2>/dev/null || true

if ! openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/device.crt" >/dev/null 2>&1; then
    echo "ERROR: Device cert does not chain to installed CA" >&2
    exit 1
fi

echo "Certificate generated:"
openssl x509 -in "$CERT_DIR/device.crt" -noout -subject -enddate
echo "Files: $CERT_DIR/{device.crt,device.key,ca.crt}"
