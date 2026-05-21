#!/usr/bin/env bash
# sign-bootfiles-fit.sh — compatibility shim.
#
# The bootfiles signing logic now lives in scripts/sign_fit.py. This
# shim preserves the legacy CLI (`--archive`, `--force`, `--` separator
# for forwarded sign-fit args) so Makefile targets and operator
# runbooks keep working. New code should call
# `python3 scripts/sign_fit.py sign-bootfiles ...` directly.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PY_TOOL="${SCRIPT_DIR}/sign_fit.py"

# Old CLI: `sign-bootfiles-fit.sh [shim-args] -- [signing-args]`.
# Python subcommand accepts the same flags directly; merge both groups
# by stripping the `--` separator.
args=()
for arg in "$@"; do
    if [[ "${arg}" == "--" ]]; then
        continue
    fi
    args+=("${arg}")
done

# Legacy default: the old shell wrapper implicitly targeted the YubiKey
# slot 9a flow and applied caller-supplied flags as per-field overrides
# on top of those defaults. Preserve that by always injecting
# `--profile yubikey-9a` unless the caller selected a profile explicitly
# via `--profile NAME` or `--profile=NAME`. All other flags override
# profile fields in Python — they no longer disable injection.
inject_default=1
for a in "${args[@]+"${args[@]}"}"; do
    case "${a}" in
        --profile|--profile=*)
            inject_default=0
            break
            ;;
    esac
done
if [[ "${inject_default}" -eq 1 ]]; then
    args=("--profile" "yubikey-9a" "${args[@]+"${args[@]}"}")
fi

exec python3 "${PY_TOOL}" sign-bootfiles "${args[@]+"${args[@]}"}"
