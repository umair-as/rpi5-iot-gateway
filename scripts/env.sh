# shellcheck shell=bash
# Source this file to make standalone `kas` invocations behave the same
# as they do under `make`. Idempotent.
#
#   . scripts/env.sh
#   kas shell -c 'bitbake -e | grep DL_DIR' kas/local.yml
#
# Why this exists:
#   The Makefile exports KAS_WORK_DIR + KAS_REPO_REF_DIR only to its own
#   sub-processes. Standalone `kas shell` invocations in your interactive
#   shell don't inherit make's environment, so kas falls back to its
#   defaults (KAS_WORK_DIR = CWD = repo root) and re-clones every upstream
#   layer in-tree. Sourcing this file once per shell session lifts the same
#   env into shell scope and avoids the in-tree pollution.
#
# KAS_WORK_DIR / KAS_BUILD_DIR default to repo-relative locations. The shared
# layer cache (KAS_REPO_REF_DIR) is host-specific and optional, so it is not
# committed — set it in the gitignored scripts/env.local.sh (copy from
# scripts/env.local.sh.example). Any pre-set value is left alone.

_IOTGW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Host-local overrides (gitignored): real KAS_REPO_REF_DIR / cache paths.
[ -f "${_IOTGW_REPO_ROOT}/scripts/env.local.sh" ] && . "${_IOTGW_REPO_ROOT}/scripts/env.local.sh"

export KAS_WORK_DIR="${KAS_WORK_DIR:-${_IOTGW_REPO_ROOT}/.kas}"
# Optional shared bare-repo layer cache (git alternates) for fast setup.
# Unset => kas does full clones (correct, just slower).
[ -n "${KAS_REPO_REF_DIR:-}" ] && export KAS_REPO_REF_DIR
# Build dir at the traditional repo-root location. Without this, kas
# defaults to ${KAS_WORK_DIR}/build (= .kas/build), which doesn't match
# the universal Yocto convention.
export KAS_BUILD_DIR="${KAS_BUILD_DIR:-${_IOTGW_REPO_ROOT}/build}"

# kas refuses to start if KAS_WORK_DIR doesn't exist (it does not mkdir it).
# The Makefile creates it at parse time; replicate for shell-scope invocations.
mkdir -p "${KAS_WORK_DIR}"

echo "rpi5-iot-gw kas env loaded:"
echo "  KAS_WORK_DIR=${KAS_WORK_DIR}"
echo "  KAS_BUILD_DIR=${KAS_BUILD_DIR}"
echo "  KAS_REPO_REF_DIR=${KAS_REPO_REF_DIR:-<unset: full clones>}"

unset _IOTGW_REPO_ROOT
