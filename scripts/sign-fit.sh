#!/usr/bin/env bash
# sign-fit.sh — re-sign a U-Boot FIT image using a key on a PKCS#11
# token (typically a YubiKey PIV slot) via OpenSSL's engine_pkcs11.
#
# Intended as a post-build release step: the build system signs the
# FIT with a file-based key; this wrapper overwrites that signature in
# place against an HSM-resident key.
#
# mkimage gotcha: `mkimage -F -N pkcs11 <fit>` without `-G` is a
# silent no-op for the signing step. It repacks the FDT, regenerates
# hashes, exits 0, and leaves the original signature bytes untouched.
# This script always passes `-G <uri>` and additionally guards
# against the trap by capturing mkimage's stdout/stderr and
# requiring at least one "Signature written" log line — that line is
# absent in the silent no-op case.
#
# The FIT's `key-name-hint` is metadata only — it determines the
# audit string in `Sign algo: <alg>:<hint>` and must match the
# `/signature/key-<hint>` node in U-Boot's control FDT for the
# device to actually verify the signature. The actual key lookup
# during signing is driven by the PKCS#11 URI passed via `-G`,
# which is decoupled from the hint (libykcs11 exposes slot 9a's
# private object under a fixed label "Private key for PIV
# Authentication", independent of the project-controlled FIT hint).
# fdtput rewrites the hint before signing so the audit line and the
# DTB key-node lookup line up.
#
# WARNING: mutates --fit in place. Run against a copy of the deploy
# artifact, not the deploy artifact directly. The script writes a
# `<fit>.bak` next to the target before any mutation and restores it
# on failure, but a successful sign-then-fail-elsewhere flow can
# still leave a partially-updated bundle pipeline if the script is
# pointed at the live deploy path.

set -euo pipefail

# Project-controlled FIT key-name-hint. Must match the /signature/key-<hint>
# node injected into U-Boot's control FDT by the kernel-fit recipe.
DEFAULT_KEY_NAME_HINT="iotgw-fit-yk-2026"

# PKCS#11 URI passed to mkimage as -k (NOT -G). U-Boot 2025.04's mkimage
# ignores -G in its `-N pkcs11` code path (lib/rsa/rsa-sign.c does not
# reference params.keyfile for the pkcs11 engine) and synthesizes the
# URI from the FIT's key-name-hint unless -k is supplied with a URI
# that already contains `object=`. libykcs11 hardcodes slot 9a's
# private-object label to "Private key for PIV Authentication", so the
# only URI form mkimage will accept verbatim for that slot is
# object-anchored to this label. Other URI forms (id=, token= without
# object=) require a signer that calls OpenSSL directly rather than
# going through mkimage's -N pkcs11 path.
DEFAULT_URI="pkcs11:object=Private%20key%20for%20PIV%20Authentication"

DEFAULT_ENGINE_CONF="${HOME}/rauc-keys/rauc-ca/fit/openssl-engine.cnf"

FIT=""
ENGINE_CONF="${DEFAULT_ENGINE_CONF}"
KEY_NAME_HINT=""
URI=""
KEY_LABEL_LEGACY=""
VERIFY=0
REWRITE_ONLY=0
VERBOSE=0

BACKUP=""
MUTATED=0

die()  { echo "sign-fit.sh: error: $*" >&2; exit 1; }
warn() { echo "sign-fit.sh: warning: $*" >&2; }
log()  { echo "sign-fit.sh: $*"; }

cleanup() {
    local rc=$?
    if [[ -n "${BACKUP}" && -f "${BACKUP}" ]]; then
        if [[ ${rc} -ne 0 && ${MUTATED} -eq 1 ]]; then
            if cp -f -- "${BACKUP}" "${FIT}" 2>/dev/null; then
                warn "restored ${FIT} from ${BACKUP} after failure (exit ${rc})"
            else
                warn "FAILED to restore ${FIT} from ${BACKUP} — inspect manually (exit ${rc})"
                return
            fi
        fi
        rm -f -- "${BACKUP}"
    fi
}
trap cleanup EXIT

# URL-encode anything outside the RFC 7512 pk11-unreserved subset.
url_encode() {
    local s="$1" i c out=""
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *)               printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

usage() {
    cat <<EOF
Usage: sign-fit.sh --fit PATH [OPTIONS]

  --fit PATH           Path to fitImage (required).
  --engine-conf PATH   OpenSSL engine config that loads engine_pkcs11
                       against the PKCS#11 module.
                       Default: ${DEFAULT_ENGINE_CONF}
  --key-name-hint NAME FIT key-name-hint to write before re-signing.
                       Drives the 'Sign algo:' audit line AND must
                       match the /signature/key-<NAME> node in
                       U-Boot's control FDT — devices reject FITs
                       whose hint doesn't resolve to a trusted key.
                       Default: "${DEFAULT_KEY_NAME_HINT}"
  --uri URI            PKCS#11 URI passed to mkimage via -k (NOT -G;
                       see comment near DEFAULT_URI). The URI MUST
                       contain 'object=<libykcs11-label>' because
                       mkimage 2025.04 only uses -k verbatim when the
                       legacy URI form is detected via that substring;
                       any other form (e.g. id=) is rewritten with an
                       appended object=<key-name-hint> which will not
                       match a real libykcs11 object. The default
                       targets slot 9a via libykcs11's hardcoded
                       private-object label. Token-anchored override
                       example:
                       'pkcs11:token=YubiKey%20PIV%20%23<SERIAL>;object=Private%20key%20for%20PIV%20Authentication'.
                       Default: "${DEFAULT_URI}"
  --key-label NAME     DEPRECATED alias. Equivalent to
                       '--key-name-hint NAME --uri pkcs11:object=
                       <urlencoded NAME>'. Kept for back-compat with
                       existing tooling that paired the libykcs11
                       object label with FIT metadata.
  --verify             Structural check after signing (NOT a crypto
                       verification). Asserts every signature node
                       has algo 'sha256,rsa2048:<KEY_NAME_HINT>' and
                       a non-empty Sign value (rejects "unavailable").
                       For cryptographic verification, run
                       'mkimage -V' against a DTB carrying the
                       expected public key.
  --rewrite-only       Mutating: rewrite the FIT key-name-hint and
                       stop before mkimage. Useful for plumbing
                       tests without touching the token. The FIT is
                       still modified — run on a copy.
  --verbose            Forward mkimage's full stdout (FIT listing,
                       per-image hashes) to the terminal. Default
                       suppresses it; on mkimage failure the
                       captured output is printed to stderr for
                       diagnostics regardless of this flag.
  -h, --help           Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fit)            [[ $# -ge 2 ]] || die "--fit needs a value"; FIT="$2"; shift 2 ;;
        --engine-conf)    [[ $# -ge 2 ]] || die "--engine-conf needs a value"; ENGINE_CONF="$2"; shift 2 ;;
        --key-name-hint)  [[ $# -ge 2 ]] || die "--key-name-hint needs a value"; KEY_NAME_HINT="$2"; shift 2 ;;
        --uri)            [[ $# -ge 2 ]] || die "--uri needs a value"; URI="$2"; shift 2 ;;
        --key-label)      [[ $# -ge 2 ]] || die "--key-label needs a value"; KEY_LABEL_LEGACY="$2"; shift 2 ;;
        --verify)       VERIFY=1; shift ;;
        --rewrite-only) REWRITE_ONLY=1; shift ;;
        --verbose)      VERBOSE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             usage >&2; die "unknown option: $1" ;;
        *)              usage >&2; die "unexpected positional argument: $1" ;;
    esac
done

[[ -n "${FIT}" ]]         || { usage >&2; die "--fit is required"; }
[[ -n "${ENGINE_CONF}" ]] || die "--engine-conf must not be empty"
[[ -f "${FIT}" ]]         || die "fitImage not found: ${FIT}"
[[ -w "${FIT}" ]]         || die "fitImage not writable: ${FIT}"
FIT_DIR="$(dirname -- "${FIT}")"
[[ -w "${FIT_DIR}" ]]     || die "cannot write backup next to ${FIT} (directory not writable: ${FIT_DIR})"
[[ -f "${ENGINE_CONF}" ]] || die "engine conf not found: ${ENGINE_CONF}"

if [[ -n "${KEY_LABEL_LEGACY}" ]]; then
    warn "--key-label is deprecated; pass --key-name-hint and --uri explicitly"
    [[ -z "${KEY_NAME_HINT}" ]] || die "--key-label and --key-name-hint are mutually exclusive"
    KEY_NAME_HINT="${KEY_LABEL_LEGACY}"
    if [[ -z "${URI}" ]]; then
        URI="pkcs11:object=$(url_encode "${KEY_LABEL_LEGACY}")"
    fi
fi

KEY_NAME_HINT="${KEY_NAME_HINT:-${DEFAULT_KEY_NAME_HINT}}"
URI="${URI:-${DEFAULT_URI}}"

[[ -n "${KEY_NAME_HINT}" ]] || die "--key-name-hint must not be empty"
[[ "${URI}" == pkcs11:* ]]  || die "URI must start with 'pkcs11:': ${URI}"
# mkimage 2025.04's -k path keeps the URI verbatim only when it contains
# 'object='. Without that substring, mkimage appends ';object=<hint>'
# which then will not match a real libykcs11 object — silent sign
# failure. Refuse early instead.
[[ "${URI}" == *"object="* ]] \
    || die "URI must contain 'object=<libykcs11-label>': mkimage 2025.04's -N pkcs11 path rewrites URIs without object= and will not find slot 9a — got: ${URI}"

for tool in fdtget fdtput mkimage; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool missing on PATH: ${tool}"
done
if [[ "${REWRITE_ONLY}" -eq 0 || "${VERIFY}" -eq 1 ]]; then
    command -v dumpimage >/dev/null 2>&1 \
        || die "dumpimage required for signing and --verify (not on PATH)"
fi

# Token presence check (best-effort; engine_pkcs11 has no serial-anchor
# CLI flag, so multi-token setups are inherently ambiguous unless --uri
# carries token=...).
if [[ "${REWRITE_ONLY}" -eq 0 ]] && command -v ykman >/dev/null 2>&1; then
    if ! ykman_out="$(ykman list 2>&1)"; then
        warn "ykman list failed (${ykman_out%%$'\n'*}) — skipping presence check"
    else
        mapfile -t yk_tokens < <(printf '%s' "${ykman_out}" | grep -v '^[[:space:]]*$' || true)
        case "${#yk_tokens[@]}" in
            0) die "no YubiKey detected on the bus (use --rewrite-only to skip signing)" ;;
            1) : ;;
            *) warn "${#yk_tokens[@]} YubiKeys detected — without 'token=' in --uri, engine_pkcs11 selects whichever it sees first" ;;
        esac
    fi
fi

# Take backup before any mutation so the EXIT trap can restore on
# failure. From here on, MUTATED=1 means the on-disk FIT differs from
# the backup.
BACKUP="${FIT}.bak"
cp -f -- "${FIT}" "${BACKUP}" || die "failed to write backup at ${BACKUP}"

# Enumerate /configurations subnodes. fdtget -l prints one subnode per
# line; properties (e.g. 'default') are not listed.
if ! confs_raw="$(fdtget -l "${FIT}" /configurations 2>&1)"; then
    die "fdtget failed to list /configurations: ${confs_raw}"
fi
mapfile -t CONFS < <(printf '%s\n' "${confs_raw}")
# Strip empties (mapfile can yield a trailing empty element).
filtered=()
for c in "${CONFS[@]}"; do [[ -n "${c}" ]] && filtered+=("${c}"); done
CONFS=("${filtered[@]}")
[[ "${#CONFS[@]}" -gt 0 ]] || die "no configuration nodes under /configurations in ${FIT}"

TOTAL_SIGS=0
for conf in "${CONFS[@]}"; do
    if ! children_raw="$(fdtget -l "${FIT}" "/configurations/${conf}" 2>&1)"; then
        die "fdtget failed to list /configurations/${conf}: ${children_raw}"
    fi
    mapfile -t CHILDREN < <(printf '%s\n' "${children_raw}")
    sig_found=0
    for child in "${CHILDREN[@]}"; do
        [[ -n "${child}" ]] || continue
        case "${child}" in
            signature*)
                MUTATED=1
                fdtput -t s "${FIT}" "/configurations/${conf}/${child}" \
                    key-name-hint "${KEY_NAME_HINT}" \
                    || die "fdtput failed on /configurations/${conf}/${child}"
                sig_found=$((sig_found+1))
                TOTAL_SIGS=$((TOTAL_SIGS+1))
                ;;
        esac
    done
    [[ "${sig_found}" -gt 0 ]] || die "no signature* nodes under /configurations/${conf}"
done
log "rewrote key-name-hint to '${KEY_NAME_HINT}' on ${TOTAL_SIGS} signature node(s) across ${#CONFS[@]} configuration(s)"

if [[ "${REWRITE_ONLY}" -eq 1 ]]; then
    log "rewrite-only: FIT key-name-hint rewritten in place; skipping mkimage"
else
    log "signing FIT via engine_pkcs11 (PIN/touch may be required)"
    log "  URI: ${URI}"

    # Capture mkimage output to detect the explicit "Signature
    # written" success line. Default is quiet — mkimage's own
    # FIT-listing dump is suppressed; on failure it is dumped to
    # stderr for diagnostics. --verbose forwards the listing live.
    #
    # PIN prompts from engine_pkcs11 are not affected: OpenSSL's UI
    # writes them to /dev/tty, bypassing stdout/stderr redirection.
    #
    # Detection by log line, not byte comparison: RSA-PKCS#1 v1.5
    # over the FIT signed range is deterministic — re-signing the
    # same FIT with the same key produces byte-identical signatures
    # and would false-positive a pre/post bytes-changed guard.
    # U-Boot 2025.04 ignores -G/keyfile in the pkcs11 RSA path.
    # Passing -k pkcs11:object=<label> is the only way to decouple
    # private-key lookup from the FIT key-name-hint.
    mk_log="$(mktemp)"
    trap 'rm -f "${mk_log}"; cleanup' EXIT
    set +e
    if [[ "${VERBOSE}" -eq 1 ]]; then
        OPENSSL_CONF="${ENGINE_CONF}" \
            mkimage -F -N pkcs11 -k "${URI}" "${FIT}" 2>&1 | tee "${mk_log}"
        mk_rc=${PIPESTATUS[0]}
    else
        OPENSSL_CONF="${ENGINE_CONF}" \
            mkimage -F -N pkcs11 -k "${URI}" "${FIT}" >"${mk_log}" 2>&1
        mk_rc=$?
    fi
    set -e
    if [[ "${mk_rc}" -ne 0 ]]; then
        echo "---- mkimage output ----" >&2
        cat "${mk_log}" >&2
        echo "------------------------" >&2
        rm -f "${mk_log}"
        die "mkimage -F failed (exit ${mk_rc})"
    fi

    sig_written_count=$(grep -c -F 'Signature written' "${mk_log}" || true)
    if [[ "${sig_written_count}" -eq 0 ]]; then
        echo "---- mkimage output ----" >&2
        cat "${mk_log}" >&2
        echo "------------------------" >&2
        rm -f "${mk_log}"
        die "mkimage exited 0 but emitted no 'Signature written' line — signing was a silent no-op (check engine config and that -G reached mkimage)"
    fi
    rm -f "${mk_log}"
    trap cleanup EXIT
    log "mkimage signed (${sig_written_count} 'Signature written' line(s) observed)"
fi

VERIFY_RESULT="skipped"
if [[ "${VERIFY}" -eq 1 ]]; then
    if ! dump_out="$(dumpimage -l "${FIT}" 2>&1)"; then
        die "dumpimage failed during --verify: ${dump_out}"
    fi
    expected_algo="sha256,rsa2048:${KEY_NAME_HINT}"

    algo_count=$(printf '%s\n' "${dump_out}" | grep -c -F 'Sign algo:' || true)
    match_count=$(printf '%s\n' "${dump_out}" | grep -c -F "${expected_algo}" || true)

    if [[ "${algo_count}" -lt "${TOTAL_SIGS}" || "${match_count}" -lt "${TOTAL_SIGS}" ]]; then
        printf '%s\n' "${dump_out}" >&2
        die "verify failed: expected ${TOTAL_SIGS} signature(s) with algo '${expected_algo}', found ${match_count}"
    fi

    bad_sigs=0
    while IFS= read -r line; do
        val="${line#*Sign value:}"
        val="$(printf '%s' "${val}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ -z "${val}" || "${val}" == "unavailable" ]]; then
            bad_sigs=$((bad_sigs+1))
        fi
    done < <(printf '%s\n' "${dump_out}" | grep -F 'Sign value:')

    if [[ "${bad_sigs}" -gt 0 ]]; then
        printf '%s\n' "${dump_out}" >&2
        die "verify failed: ${bad_sigs} signature node(s) have empty or 'unavailable' Sign value"
    fi

    VERIFY_RESULT="PASS (${match_count} signature(s) matched '${expected_algo}')"
    log "verify: ${VERIFY_RESULT}"
fi

if [[ "${REWRITE_ONLY}" -eq 1 ]]; then
    MODE="rewrite-only (FIT mutated, mkimage skipped)"
else
    MODE="signed via engine_pkcs11"
fi

echo
echo "================ sign-fit summary ================"
printf "  FIT image       : %s\n" "${FIT}"
printf "  Key name hint   : %s\n" "${KEY_NAME_HINT}"
printf "  PKCS#11 URI     : %s\n" "${URI}"
printf "  Engine conf     : %s\n" "${ENGINE_CONF}"
printf "  Configurations  : %d\n" "${#CONFS[@]}"
printf "  Signature nodes : %d\n" "${TOTAL_SIGS}"
printf "  Mode            : %s\n" "${MODE}"
printf "  Verify          : %s\n" "${VERIFY_RESULT}"
printf "  Timestamp       : %s\n" "$(date -u +%FT%TZ)"
echo "=================================================="
