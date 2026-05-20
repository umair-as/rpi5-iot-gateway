#!/usr/bin/env bash
# sign-bootfiles-fit.sh — re-sign the fitImage embedded in a
# `bootfiles-fit.tar.gz` archive against a PKCS#11-resident key.
#
# Wraps `sign-fit.sh` to operate on the bootfiles tarball that the
# RAUC bundle recipe consumes. After this script runs, the bundle
# recipe must be re-driven (e.g. via `bitbake -C do_configure
# iot-gw-bundle-full-fit`) so the bundle re-packages with the
# updated tarball.
#
# Flow:
#   1. Snapshot the archive (`<archive>.bak`) for rollback.
#   2. Extract into a temp dir.
#   3. Run scripts/sign-fit.sh on the extracted fitImage.
#   4. Re-pack the tarball in place.
#   5. Print SHA-256 of old/new archives.
#
# WARNING: mutates the bootfiles tarball in place. The script
# restores the backup if any step after extraction fails.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SIGN_FIT="${SCRIPT_DIR}/sign-fit.sh"

DEFAULT_ARCHIVE="build/tmp-glibc/deploy/images/raspberrypi5/bootfiles-fit.tar.gz"

ARCHIVE=""
PASSTHROUGH=()
FORCE=0

BACKUP=""
TMPDIR_WORK=""
MUTATED=0

die()  { echo "sign-bootfiles-fit.sh: error: $*" >&2; exit 1; }
warn() { echo "sign-bootfiles-fit.sh: warning: $*" >&2; }
log()  { echo "sign-bootfiles-fit.sh: $*"; }

cleanup() {
    local rc=$?
    if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then
        if [[ ${rc} -ne 0 && ${MUTATED} -eq 1 ]]; then
            if cp -f -- "${BACKUP}" "${ARCHIVE}" 2>/dev/null; then
                warn "restored ${ARCHIVE} from ${BACKUP} after failure (exit ${rc})"
            else
                warn "FAILED to restore ${ARCHIVE} from ${BACKUP} — inspect manually (exit ${rc})"
            fi
        fi
        rm -f -- "${BACKUP}"
    fi
    if [[ -n "${TMPDIR_WORK}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf -- "${TMPDIR_WORK}"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: sign-bootfiles-fit.sh [--archive PATH] [-- <sign-fit.sh args>...]

  --archive PATH   Path to bootfiles-fit.tar.gz.
                   Default: ${DEFAULT_ARCHIVE}
  --force          Re-sign even when the inner FIT already advertises
                   the HSM key-name-hint in its 'Sign algo:' audit
                   line. Useful when refreshing signature timestamps
                   or recovering from a tampered audit field.
  -h, --help       Show this help and exit.

All arguments after '--' are forwarded to sign-fit.sh. Useful
forwards: --key-name-hint, --uri, --engine-conf, --verify.

Example:
  sign-bootfiles-fit.sh -- --verify
  sign-bootfiles-fit.sh --archive /path/to/bootfiles-fit.tar.gz -- \\
      --uri 'pkcs11:token=<encoded>;id=%01;type=private' --verify
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) [[ $# -ge 2 ]] || die "--archive needs a value"; ARCHIVE="$2"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; PASSTHROUGH=("$@"); break ;;
        -*)        usage >&2; die "unknown option: $1 (forwards to sign-fit.sh go after '--')" ;;
        *)         usage >&2; die "unexpected positional argument: $1" ;;
    esac
done

[[ -n "${ARCHIVE}" ]] || ARCHIVE="${DEFAULT_ARCHIVE}"
[[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"
[[ -w "${ARCHIVE}" ]] || die "archive not writable: ${ARCHIVE}"
[[ -x "${SIGN_FIT}" ]] || die "helper not found or not executable: ${SIGN_FIT}"

# Resolve to absolute path so the repack subshell's `cd` into TMPDIR_WORK
# cannot break the archive reference.
ARCHIVE="$(readlink -f -- "${ARCHIVE}")" || die "could not resolve absolute path of ${ARCHIVE}"
ARCHIVE_DIR="$(dirname -- "${ARCHIVE}")"
[[ -w "${ARCHIVE_DIR}" ]] || die "archive directory not writable: ${ARCHIVE_DIR}"

for tool in tar sha256sum dumpimage; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool missing on PATH: ${tool}"
done

PRE_SHA="$(sha256sum -- "${ARCHIVE}" | awk '{print $1}')"
log "archive: ${ARCHIVE}"
log "pre  sha256: ${PRE_SHA}"

# Content-based idempotency check: peek at the inner FIT's `Sign algo:`
# audit line. If it already advertises the HSM key-name-hint we would
# sign with, skip — this is the signal a downstream consumer
# (operator, signing service, U-Boot DTB verify) reads. The check is
# spoofable in principle (someone could rewrite the FIT's
# key-name-hint without actually signing with the HSM); for the
# Stage 1 → Stage 2 flow that this script supports, the trade-off
# favours an in-artifact signal over a sidecar trust file that does
# not travel across machines. Use --force to override.
#
# Effective FIT key-name-hint is what sign-fit.sh will write: parse
# PASSTHROUGH for an explicit --key-name-hint, fall back to the
# deprecated --key-label alias if present, otherwise use sign-fit.sh's
# documented default (kept in sync with DEFAULT_KEY_NAME_HINT there).
DEFAULT_KEY_NAME_HINT="iotgw-fit-yk-2026"
EFFECTIVE_HINT="${DEFAULT_KEY_NAME_HINT}"
for ((i=0; i<${#PASSTHROUGH[@]}; i++)); do
    if [[ "${PASSTHROUGH[i]}" == "--key-name-hint" && $((i+1)) -lt ${#PASSTHROUGH[@]} ]]; then
        EFFECTIVE_HINT="${PASSTHROUGH[i+1]}"
        break
    fi
    if [[ "${PASSTHROUGH[i]}" == "--key-label" && $((i+1)) -lt ${#PASSTHROUGH[@]} ]]; then
        EFFECTIVE_HINT="${PASSTHROUGH[i+1]}"
        # don't break — a later --key-name-hint should still win
    fi
done
EXPECTED_ALGO="sha256,rsa2048:${EFFECTIVE_HINT}"

if [[ "${FORCE}" -eq 0 ]]; then
    peek_dir="$(mktemp -d -t sign-bootfiles-peek.XXXXXX)"
    algo_total=0
    algo_match=0
    if tar -xzf "${ARCHIVE}" -C "${peek_dir}" ./fitImage 2>/dev/null \
            && [[ -f "${peek_dir}/fitImage" ]]; then
        # Skip only if every `Sign algo:` line in the FIT matches the
        # expected algo. A partial state (one config labelled, another
        # still showing the file-key label) must NOT skip — that would
        # ship a mixed-trust bundle silently.
        mapfile -t algo_lines < <(dumpimage -l "${peek_dir}/fitImage" 2>/dev/null \
            | grep -F 'Sign algo:' || true)
        algo_total="${#algo_lines[@]}"
        for line in "${algo_lines[@]}"; do
            if [[ "${line}" == *"${EXPECTED_ALGO}"* ]]; then
                algo_match=$((algo_match + 1))
            fi
        done
    fi
    rm -rf -- "${peek_dir}"
    if [[ "${algo_total}" -gt 0 && "${algo_match}" -eq "${algo_total}" ]]; then
        log "all ${algo_total} signature node(s) in inner FIT already labelled '${EXPECTED_ALGO}'; skipping (use --force to re-sign)"
        echo
        echo "============ sign-bootfiles-fit summary ============"
        printf "  Archive       : %s\n" "${ARCHIVE}"
        printf "  SHA           : %s\n" "${PRE_SHA}"
        printf "  Inner FIT     : all %d signature node(s) labelled '%s'\n" "${algo_total}" "${EXPECTED_ALGO}"
        printf "  Mode          : skipped (use --force to re-sign)\n"
        printf "  Timestamp     : %s\n" "$(date -u +%FT%TZ)"
        echo "===================================================="
        exit 0
    fi
    if [[ "${algo_total}" -gt 0 && "${algo_match}" -gt 0 ]]; then
        log "inner FIT is partially labelled (${algo_match} of ${algo_total} signature node(s) match '${EXPECTED_ALGO}'); proceeding to re-sign all"
    fi
fi

BACKUP="${ARCHIVE}.bak"
cp -f -- "${ARCHIVE}" "${BACKUP}" || die "failed to write backup at ${BACKUP}"

TMPDIR_WORK="$(mktemp -d -t sign-bootfiles-fit.XXXXXX)"
log "extracting into ${TMPDIR_WORK}"
tar -xzf "${ARCHIVE}" -C "${TMPDIR_WORK}" || die "tar extract failed"

EXTRACTED_FIT="${TMPDIR_WORK}/fitImage"
[[ -f "${EXTRACTED_FIT}" ]] || die "fitImage not found in archive (looked at ${EXTRACTED_FIT})"

log "invoking sign-fit.sh on extracted fitImage"
MUTATED=1
"${SIGN_FIT}" --fit "${EXTRACTED_FIT}" "${PASSTHROUGH[@]}"

log "repacking ${ARCHIVE}"
# Re-pack from TMPDIR_WORK with the same ./<files> layout the original
# archive used (verified to start with './' entries by the bundle recipe).
( cd "${TMPDIR_WORK}" && tar -czf "${ARCHIVE}.new" . ) \
    || die "tar repack failed"
mv -f -- "${ARCHIVE}.new" "${ARCHIVE}" \
    || die "failed to replace ${ARCHIVE} with repacked archive"

POST_SHA="$(sha256sum -- "${ARCHIVE}" | awk '{print $1}')"
log "post sha256: ${POST_SHA}"

if [[ "${PRE_SHA}" == "${POST_SHA}" ]]; then
    die "archive SHA unchanged after repack — sign-fit.sh likely no-op'd; check args (need --verify or signing args after '--')"
fi

echo
echo "============ sign-bootfiles-fit summary ============"
printf "  Archive   : %s\n" "${ARCHIVE}"
printf "  Pre  SHA  : %s\n" "${PRE_SHA}"
printf "  Post SHA  : %s\n" "${POST_SHA}"
printf "  Inner FIT : signed (audit line '%s')\n" "${EXPECTED_ALGO}"
printf "  Timestamp : %s\n" "$(date -u +%FT%TZ)"
echo
echo "Next step: re-drive the bundle recipe so it picks up the new"
echo "tarball. With this project's KAS+make wrapper, that is:"
echo "  make bundle-dev-full-fit-resign"
echo "===================================================="
