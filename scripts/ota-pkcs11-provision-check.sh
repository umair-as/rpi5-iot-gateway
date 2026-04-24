#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-iotgw}"
TOKEN_LABEL="${TOKEN_LABEL:-iotgw}"
KEY_LABEL="${KEY_LABEL:-rauc-client-key}"
MODULE_PATH="${MODULE_PATH:-/usr/lib/pkcs11/libtpm2_pkcs11.so}"

echo "[pkcs11-check] target=${TARGET}"
echo "[pkcs11-check] token=${TOKEN_LABEL} key=${KEY_LABEL}"

ssh "${TARGET}" "set -euo pipefail
echo '[pkcs11-check] tool availability:'
command -v pkcs11-tool >/dev/null && echo '  - pkcs11-tool: OK' || echo '  - pkcs11-tool: MISSING'
if command -v tpm2_ptool >/dev/null; then
  echo '  - tpm2_ptool: OK'
elif command -v tpm2_ptool.py >/dev/null; then
  echo '  - tpm2_ptool.py: OK'
else
  echo '  - tpm2_ptool: MISSING (install tpm2-pkcs11 tools package)'
fi

echo
echo '[pkcs11-check] slots:'
pkcs11-tool --module '${MODULE_PATH}' -L || true

echo
echo '[pkcs11-check] object lookup:'
pkcs11-tool --module '${MODULE_PATH}' -O --login 2>/dev/null | grep -E 'Label:|ID:' || true

echo
echo '[pkcs11-check] expected URI:'
echo '  pkcs11:token=${TOKEN_LABEL};object=${KEY_LABEL};type=private'

echo
echo '[pkcs11-check] next provisioning steps (run on target as root):'
cat <<'EOF'
# 1) Inspect local tool syntax first (varies by distro build):
tpm2_ptool --help || tpm2_ptool.py --help

# 2) Initialize token store and create token/object:
#    (use the command variants shown by --help for your target build)
#    Typical flow:
#      - init store
#      - add token label 'iotgw' with SO PIN + user PIN
#      - add private key object label 'rauc-client-key'

# 3) Verify token/object exists:
pkcs11-tool --module /usr/lib/pkcs11/libtpm2_pkcs11.so -L
pkcs11-tool --module /usr/lib/pkcs11/libtpm2_pkcs11.so -O --login

# 4) Validate mTLS key loading with same URI RAUC uses:
PKCS11_MODULE_PATH=/usr/lib/pkcs11/libtpm2_pkcs11.so \
curl -vk --cert /etc/ota/device.crt \
  --key 'pkcs11:token=iotgw;object=rauc-client-key;type=private' \
  --cacert /etc/ota/ca.crt \
  'https://<ota-host>:8443/api/v1/manifest.json?compatible=iot-gateway-raspberrypi5' \
  -o /tmp/manifest.out
EOF
"
