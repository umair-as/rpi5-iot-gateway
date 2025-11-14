#!/bin/bash
# Generate RAUC development certificates
# For production, use proper CA-signed certificates!

set -e

CERT_DIR="$(dirname $0)/../recipes-ota/rauc/files"
mkdir -p "$CERT_DIR"

echo "Generating RAUC development certificates..."

# Generate private key
openssl genrsa -out "$CERT_DIR/dev-key.pem" 4096

# Generate self-signed certificate (valid for 10 years)
openssl req -new -x509 -key "$CERT_DIR/dev-key.pem" \
    -out "$CERT_DIR/dev-cert.pem" -days 3650 \
    -subj "/C=US/ST=State/L=City/O=IoTGateway/OU=Development/CN=iot-gateway-rpi5"

# Create CA certificate keyring (for target device)
cp "$CERT_DIR/dev-cert.pem" "$CERT_DIR/ca.cert.pem"

echo "Certificates generated successfully!"
echo "  Private key: $CERT_DIR/dev-key.pem (KEEP SECURE!)"
echo "  Certificate: $CERT_DIR/dev-cert.pem"
echo "  CA Keyring:  $CERT_DIR/ca.cert.pem"
echo ""
echo "WARNING: These are development certificates only!"
echo "For production, generate proper CA-signed certificates."
