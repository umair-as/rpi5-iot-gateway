#!/usr/bin/env bash
# sign-fit.sh — compatibility shim.
#
# The signing logic now lives in scripts/sign_fit.py. This shim
# preserves the legacy CLI (`--fit`, `--key-name-hint`, `--uri`,
# `--engine-conf`, `--verify`, `--rewrite-only`, `--verbose`,
# `--key-label`) so Makefile targets, operator runbooks, and
# external automation keep working. New code should call
# `python3 scripts/sign_fit.py sign-fit ...` directly.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PY_TOOL="${SCRIPT_DIR}/sign_fit.py"

# Pass through everything except the legacy bare `--` terminator: in
# the old script anything after `--` was silently discarded.
args=()
for arg in "$@"; do
    if [[ "${arg}" == "--" ]]; then
        break
    fi
    args+=("${arg}")
done

# Legacy default: the old shell script implicitly targeted the YubiKey
# slot 9a flow and applied caller-supplied flags as per-field overrides
# on top of those defaults (e.g. `--engine-conf /alt.cnf` only changed
# the engine config, key hint and URI kept the YK defaults). Preserve
# that by always injecting `--profile yubikey-9a` unless the caller
# selected a profile explicitly via `--profile NAME` or `--profile=NAME`.
# All other flags (--key-name-hint / --key-label / --uri / --engine-conf)
# override profile fields in Python — they no longer disable injection.
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

exec python3 "${PY_TOOL}" sign-fit "${args[@]+"${args[@]}"}"
