#!/usr/bin/env bash
set -euo pipefail

# This script expects to be run from the repo root.
# It locates the latest built kernel .config and the native kernel-hardening-checker
# binary (or falls back to the source script), then runs the checker.

cd build

# Prepare report path (override with KHC_OUT if set)
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p reports
out=${KHC_OUT:-reports/kernel-hardening-${ts}.txt}

cfg=$(ls -1t tmp/work/*/linux-raspberrypi/*/linux-raspberrypi5-standard-build/.config 2>/dev/null | head -n1 || true)
if [[ -z "${cfg}" ]]; then
  echo "No built kernel .config found under tmp/work" | tee -a "$out"
  exit 1
fi

# Prefer running directly from the native sysroot share to avoid absolute /usr paths
khc_share_native=$(ls -1d tmp/work/*/kernel-hardening-checker-native/*/recipe-sysroot-native/usr/share/kernel-hardening-checker 2>/dev/null | head -n1 || true)
if [[ -z "${khc_share_native}" ]]; then
  khc_share_native=$(ls -1d tmp/sysroots-components/x86_64/kernel-hardening-checker-native/usr/share/kernel-hardening-checker 2>/dev/null | head -n1 || true)
fi
if [[ -n "${khc_share_native}" ]]; then
  export PYTHONPATH="${khc_share_native}:${PYTHONPATH:-}"
  cmd=(python3 "${khc_share_native}/bin/kernel-hardening-checker" -c "${cfg}" -m verbose)
  "${cmd[@]}" >"$out" 2>&1 || true
  : > /dev/null
  echo "Using ${cfg}" >>"$out"
  # Print brief summary to console
  fails=$(grep -Ec "\|[[:space:]]+FAIL|\[FAIL\]" "$out" || true)
  warns=$(grep -Ec "\|[[:space:]]+WARN|\[WARN\]" "$out" || true)
  echo "kernel-hardening-checker: FAIL=${fails} WARN=${warns}. Full report: $out"
  exit 0
fi
if [[ -z "${khc}" ]]; then
  khc=$(ls -1 tmp/work/*/kernel-hardening-checker-native/*/image/usr/bin/kernel-hardening-checker 2>/dev/null | head -n1 || true)
fi

if [[ -z "${khc}" ]]; then
  src=$(ls -1d tmp/work/*/kernel-hardening-checker-native/*/git 2>/dev/null | head -n1 || true)
  if [[ -n "${src}" ]]; then
    if [[ -x "${src}/khc" ]]; then
      "${src}/khc" -c "${cfg}" -m verbose >"$out" 2>&1 || true
    elif [[ -f "${src}/kernel-hardening-checker.py" ]]; then
      python3 "${src}/kernel-hardening-checker.py" -c "${cfg}" -m verbose >"$out" 2>&1 || true
    fi
    echo "Using ${cfg}" >>"$out"
    fails=$(grep -Ec "\|[[:space:]]+FAIL|\[FAIL\]" "$out" || true)
    warns=$(grep -Ec "\|[[:space:]]+WARN|\[WARN\]" "$out" || true)
    echo "kernel-hardening-checker: FAIL=${fails} WARN=${warns}. Full report: $out"
    exit 0
  fi
  echo "kernel-hardening-checker artifact not found"
  exit 1
fi

"${khc}" -c "${cfg}" -m verbose >"$out" 2>&1 || true
echo "Using ${cfg}" >>"$out"
fails=$(grep -Ec "\|[[:space:]]+FAIL|\[FAIL\]" "$out" || true)
warns=$(grep -Ec "\|[[:space:]]+WARN|\[WARN\]" "$out" || true)
echo "kernel-hardening-checker: FAIL=${fails} WARN=${warns}. Full report: $out"
