#!/usr/bin/env bash
set -euo pipefail

# Non-destructive TPM2/LUKS2 self-test for target runtime.
# Uses a file-backed LUKS2 container under /data and removes artifacts by default.
#
# Usage:
#   scp scripts/tpm/tpm-cryptenroll-selftest.sh root@iotgw:/tmp/
#   ssh root@iotgw 'bash /tmp/tpm-cryptenroll-selftest.sh'
#
# Optional env vars:
#   TEST_IMG=/data/tpm-luks2-test.img
#   MAP_NAME=tpmtest
#   KEY_FILE=/run/tpmtest.key
#   TPM2_PCRS=7
#   TPM2_DEVICE=auto
#   FORCE=0            # set to 1 to replace an existing TEST_IMG
#   KEEP_ARTIFACTS=0   # set to 1 to keep image/key after test

TEST_IMG="${TEST_IMG:-/data/tpm-luks2-test.img}"
MAP_NAME="${MAP_NAME:-tpmtest}"
KEY_FILE="${KEY_FILE:-/run/tpmtest.key}"
TPM2_PCRS="${TPM2_PCRS:-7}"
TPM2_DEVICE="${TPM2_DEVICE:-auto}"
FORCE="${FORCE:-0}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
ENROLL_LOG=""
WIPE_LOG=""
CREATED_MAPPER=0
CREATED_TEST_IMG=0
CREATED_KEY_FILE=0

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '[INFO] %s\n' "$1"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
    exit 1
  fi
}

cleanup() {
  if [ "$CREATED_MAPPER" = "1" ]; then
    systemd-cryptsetup detach "$MAP_NAME" >/dev/null 2>&1 || \
      cryptsetup close "$MAP_NAME" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_ARTIFACTS" != "1" ]; then
    [ "$CREATED_TEST_IMG" = "1" ] && rm -f "$TEST_IMG" >/dev/null 2>&1 || true
    [ "$CREATED_KEY_FILE" = "1" ] && rm -f "$KEY_FILE" >/dev/null 2>&1 || true
    rm -f "$ENROLL_LOG" "$WIPE_LOG" >/dev/null 2>&1 || true
  else
    rm -f "$ENROLL_LOG" "$WIPE_LOG" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

for c in cryptsetup systemd-cryptenroll systemd-cryptsetup tpm2_getcap awk sed grep head base64 stat mktemp; do
  need_cmd "$c"
done

if [ -e "/dev/mapper/$MAP_NAME" ]; then
  fail "/dev/mapper/$MAP_NAME already exists; refusing to close or reuse an existing mapping"
  exit 1
fi

if [ -e "$TEST_IMG" ]; then
  if [ "$FORCE" = "1" ]; then
    rm -f "$TEST_IMG"
  else
    fail "$TEST_IMG already exists; set FORCE=1 to replace this disposable test image"
    exit 1
  fi
fi

if [ -e "$KEY_FILE" ]; then
  if [ "$FORCE" = "1" ]; then
    rm -f "$KEY_FILE"
  else
    fail "$KEY_FILE already exists; set FORCE=1 to replace this disposable test key"
    exit 1
  fi
fi

ENROLL_LOG=$(mktemp /run/tpm-enroll.XXXXXX)
WIPE_LOG=$(mktemp /run/tpm-wipe.XXXXXX)

info "Checking TPM device"
if [ ! -c /dev/tpmrm0 ] && [ ! -c /dev/tpm0 ]; then
  fail "no TPM character device found (/dev/tpmrm0 or /dev/tpm0)"
  exit 1
fi
pass "TPM device node present"

info "Checking kernel dm-crypt support"
dm_crypt_ok=0

# Built-in kernel case.
if [ -d /sys/module/dm_crypt ]; then
  dm_crypt_ok=1
fi

# Module case.
if [ "$dm_crypt_ok" -eq 0 ]; then
  if ! grep -q '^dm_crypt ' /proc/modules 2>/dev/null; then
    modprobe dm-crypt >/dev/null 2>&1 || true
  fi
  if grep -q '^dm_crypt ' /proc/modules 2>/dev/null; then
    dm_crypt_ok=1
  fi
fi

if [ "$dm_crypt_ok" -eq 0 ]; then
  fail "dm-crypt kernel support missing (CONFIG_DM_CRYPT/module not available)"
  echo
  echo "Hint: enable CONFIG_DM_CRYPT and CONFIG_CRYPTO_XTS in kernel config." >&2
  echo "Stopping before cryptsetup open test." >&2
  exit 2
fi
pass "dm-crypt available (built-in or module)"

info "Creating test image: $TEST_IMG"
truncate -s 64M "$TEST_IMG"
CREATED_TEST_IMG=1
pass "64MiB image created"

info "Generating temporary passphrase file"
head -c 32 /dev/urandom | base64 > "$KEY_FILE"
chmod 600 "$KEY_FILE"
CREATED_KEY_FILE=1
pass "temporary key generated"

info "Formatting LUKS2 container"
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEY_FILE" "$TEST_IMG"
pass "luksFormat completed"

info "Enrolling TPM2 token (PCRs: $TPM2_PCRS, device: $TPM2_DEVICE)"
if ! systemd-cryptenroll "$TEST_IMG" \
  --unlock-key-file="$KEY_FILE" \
  --tpm2-device="$TPM2_DEVICE" \
  --tpm2-pcrs="$TPM2_PCRS" >"$ENROLL_LOG" 2>&1; then
  cat "$ENROLL_LOG" >&2 || true
  fail "systemd-cryptenroll failed"
  exit 1
fi
pass "systemd-cryptenroll succeeded"

if cryptsetup luksDump "$TEST_IMG" | grep -q 'systemd-tpm2'; then
  pass "LUKS token contains systemd-tpm2"
else
  fail "LUKS token missing systemd-tpm2"
  exit 1
fi

info "Wiping original passphrase slot to force TPM-token unlock"
if ! systemd-cryptenroll "$TEST_IMG" \
  --unlock-key-file="$KEY_FILE" \
  --wipe-slot=password >"$WIPE_LOG" 2>&1; then
  cat "$WIPE_LOG" >&2 || true
  fail "password slot wipe failed"
  exit 1
fi
pass "password slot wiped"

info "Opening mapping with TPM2 token"
systemd-cryptsetup attach "$MAP_NAME" "$TEST_IMG" - "tpm2-device=$TPM2_DEVICE"
CREATED_MAPPER=1
if [ -e "/dev/mapper/$MAP_NAME" ]; then
  pass "systemd-cryptsetup attach created /dev/mapper/$MAP_NAME"
else
  fail "TPM-token unlock did not create mapper node"
  exit 1
fi
systemd-cryptsetup detach "$MAP_NAME"
CREATED_MAPPER=0
pass "systemd-cryptsetup detach succeeded"

echo
printf 'Summary: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
