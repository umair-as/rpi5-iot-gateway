#!/bin/bash
set -u

OUTDIR="/data/ota/tpm"
umask 077
mkdir -p "$OUTDIR"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_file="${OUTDIR}/health-${ts}.log"
json_file="${OUTDIR}/health-${ts}.json"
log_basename="$(basename "$log_file")"
json_basename="$(basename "$json_file")"
latest_log="${OUTDIR}/health-latest.log"
latest_json="${OUTDIR}/health-latest.json"

boot_id="unknown"
if [ -r /proc/sys/kernel/random/boot_id ]; then
    boot_id="$(cat /proc/sys/kernel/random/boot_id)"
fi

slot_booted="unknown"
if command -v rauc >/dev/null 2>&1; then
    slot_booted="$(rauc status --output-format=shell 2>/dev/null | sed -n -e "s/^RAUC_SYSTEM_BOOTED_BOOTNAME='\\([^']*\\)'$/\\1/p" -e 's/^RAUC_SYSTEM_BOOTED_BOOTNAME=\"\\([^\"]*\\)\"$/\\1/p' | head -n 1)"
    if [ -z "$slot_booted" ]; then
        slot_booted="unknown"
    fi
fi

log() {
    printf '%s\n' "$*" >>"$log_file"
}

run_check() {
    local name="$1"
    shift
    log "== ${name} =="
    log "+ $*"
    "$@" >>"$log_file" 2>&1
    local rc=$?
    log "rc=${rc}"
    log ""
    return "$rc"
}

log "timestamp_utc=${iso_now}"
log "boot_id=${boot_id}"
log "slot_booted=${slot_booted}"
log ""

has_tpmrm0=0
has_tpm0=0

if [ -e /dev/tpmrm0 ]; then
    has_tpmrm0=1
fi
if [ -e /dev/tpm0 ]; then
    has_tpm0=1
fi

log "== device_nodes =="
ls -l /dev/tpm* >>"$log_file" 2>&1 || true
log ""

rc_tpm_ops_version=127
rc_tpm_ops_selftest=127
rc_tpm_ops_info=127
rc_tpm_ops_pcr0=127
rc_tpm_ops_pcr1=127
rc_tpm_ops_pcr7=127

if command -v tpm-ops >/dev/null 2>&1; then
    run_check "tpm_ops_version" tpm-ops version; rc_tpm_ops_version=$?
    run_check "tpm_ops_selftest" tpm-ops selftest; rc_tpm_ops_selftest=$?
    run_check "tpm_ops_info" tpm-ops info; rc_tpm_ops_info=$?
    run_check "tpm_ops_pcr0" tpm-ops pcr -i 0 -a sha256; rc_tpm_ops_pcr0=$?
    run_check "tpm_ops_pcr1" tpm-ops pcr -i 1 -a sha256; rc_tpm_ops_pcr1=$?
    run_check "tpm_ops_pcr7" tpm-ops pcr -i 7 -a sha256; rc_tpm_ops_pcr7=$?
else
    log "tpm-ops not found on PATH"
fi

rc_tpm2_getcap=127
rc_tpm2_pcrread=127

if command -v tpm2_getcap >/dev/null 2>&1; then
    run_check "tpm2_getcap_properties_fixed" tpm2_getcap properties-fixed; rc_tpm2_getcap=$?
fi

if command -v tpm2_pcrread >/dev/null 2>&1; then
    run_check "tpm2_pcrread_sha256_0_1_7" tpm2_pcrread sha256:0,1,7; rc_tpm2_pcrread=$?
fi

status="degraded"
if [ "$has_tpmrm0" -eq 1 ] && \
   [ "$rc_tpm_ops_selftest" -eq 0 ] && \
   [ "$rc_tpm_ops_info" -eq 0 ] && \
   [ "$rc_tpm_ops_pcr0" -eq 0 ] && \
   [ "$rc_tpm_ops_pcr1" -eq 0 ] && \
   [ "$rc_tpm_ops_pcr7" -eq 0 ]; then
    status="ok"
fi

cat >"$json_file" <<EOF
{
  "schema": "iotgw.tpm.health.v1",
  "timestamp_utc": "${iso_now}",
  "boot_id": "${boot_id}",
  "slot_booted": "${slot_booted}",
  "status": "${status}",
  "device_nodes": {
    "tpmrm0_present": ${has_tpmrm0},
    "tpm0_present": ${has_tpm0}
  },
  "checks": {
    "tpm_ops_version_rc": ${rc_tpm_ops_version},
    "tpm_ops_selftest_rc": ${rc_tpm_ops_selftest},
    "tpm_ops_info_rc": ${rc_tpm_ops_info},
    "tpm_ops_pcr0_rc": ${rc_tpm_ops_pcr0},
    "tpm_ops_pcr1_rc": ${rc_tpm_ops_pcr1},
    "tpm_ops_pcr7_rc": ${rc_tpm_ops_pcr7},
    "tpm2_getcap_rc": ${rc_tpm2_getcap},
    "tpm2_pcrread_rc": ${rc_tpm2_pcrread}
  },
  "artifacts": {
    "log_file": "${log_basename}",
    "json_file": "${json_basename}"
  }
}
EOF

ln -sfn "$log_basename" "$latest_log"
ln -sfn "$json_basename" "$latest_json"

echo "[iotgw-tpm-health] status=${status} json=${json_file} log=${log_file}" >&2
exit 0
