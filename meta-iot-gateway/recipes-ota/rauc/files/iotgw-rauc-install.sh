#!/usr/bin/env bash
# iotgw-rauc-install — RAUC install wrapper
#
# Responsibilities:
#   1. Re-dispatch via systemd-run for consistent privilege/namespace semantics
#   2. Reconcile OTA certificates before HTTPS streaming installs
#   3. Preflight connectivity check (single mTLS curl) for HTTPS URLs
#   4. Remount /boot read-write if U-Boot env lives there (fw_env.config)
#   5. Visual progress bar and result display
#
# TLS configuration for HTTPS streaming is read from /etc/rauc/system.conf
# [streaming] section — rauc handles it natively; no CLI override needed.
set -euo pipefail

# ── state ─────────────────────────────────────────────────────────────────────
BOOT_MP="/boot"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INSTALL_RC=0
DRY_RUN=0
DIRECT_MODE=0
NO_SYSTEMD_RUN=0
VERBOSE=0
BOOT_RW_REQUIRED=0
IS_URL=0
BUNDLE_INPUT=""
EXTRA_ARGS=()
URL_HOST=""
URL_PORT=""
TLS_CA="" TLS_CERT="" TLS_KEY=""
MOUNTED_BY_US=0 RO_BEFORE=0 REMOUNTED_RW=0

# ── terminal & colour ─────────────────────────────────────────────────────────
IS_TTY=0; [ -t 2 ] && IS_TTY=1
if [ "${IS_TTY}" -eq 1 ]; then
    _CR=$'\033[0m'      _BGREEN=$'\033[1;32m'  _YELLOW=$'\033[0;33m'
    _BRED=$'\033[1;31m' _GRAY=$'\033[0;90m'    _BOLD=$'\033[1m'  _CYAN=$'\033[0;36m'
else
    _CR='' _BGREEN='' _YELLOW='' _BRED='' _GRAY='' _BOLD='' _CYAN=''
fi
_SPIN_PID=""
_CHECK_W=44   # label column width for check lines

# ── logging ───────────────────────────────────────────────────────────────────
_syslog() { if command -v logger >/dev/null 2>&1; then logger -t iotgw-rauc-install "run=${RUN_ID} $*" || true; fi; }

_log() {
    _syslog "$*"
    if [ "${VERBOSE}" -eq 1 ]; then
        printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2
    fi
}

die() {
    _syslog "ERROR: $*"
    _spin_stop 2>/dev/null || true
    printf '\n%sError:%s %s\n' "${_BRED}" "${_CR}" "$*" >&2
    exit 1
}

# ── spinner ───────────────────────────────────────────────────────────────────
_spin_stop() {
    [ -n "${_SPIN_PID}" ] || return 0
    kill "${_SPIN_PID}" 2>/dev/null || true
    wait "${_SPIN_PID}" 2>/dev/null || true
    _SPIN_PID=""
}

_spin_start() {
    [ "${IS_TTY}" -eq 1 ] && [ "${VERBOSE}" -eq 0 ] || return 0
    local label="$1"
    (   local chars='-/|' i=0
        trap 'exit 0' TERM INT
        while true; do
            printf '\r  %s%s%s  %s' "${_CYAN}" "${chars:$(( i % 3 )):1}" "${_CR}" "${label}" >&2
            sleep 0.2; i=$(( i + 1 ))
        done
    ) &
    _SPIN_PID=$!
}

# ── check-line display ────────────────────────────────────────────────────────
_check_ok() {
    local label="$1" detail="${2:-}"
    _spin_stop
    [ "${VERBOSE}" -eq 1 ] && return 0
    if [ "${IS_TTY}" -eq 1 ]; then
        printf '\r  %s✓%s  %-*s%s\n' "${_BGREEN}" "${_CR}" "${_CHECK_W}" "${label}" \
            "${detail:+  ${_GRAY}${detail}${_CR}}" >&2
    else
        printf '  +  %-*s%s\n' "${_CHECK_W}" "${label}" "${detail:+  ${detail}}" >&2
    fi
}

_check_fail() {
    local label="$1" detail="${2:-}"
    _spin_stop
    [ "${VERBOSE}" -eq 1 ] && return 0
    if [ "${IS_TTY}" -eq 1 ]; then
        printf '\r  %s✗%s  %-*s%s\n' "${_BRED}" "${_CR}" "${_CHECK_W}" "${label}" \
            "${detail:+  ${_GRAY}${detail}${_CR}}" >&2
    else
        printf '  !  %-*s%s\n' "${_CHECK_W}" "${label}" "${detail:+  ${detail}}" >&2
    fi
}

_check_skip() {
    local label="$1" reason="${2:-}"
    _spin_stop
    [ "${VERBOSE}" -eq 1 ] && return 0
    if [ "${IS_TTY}" -eq 1 ]; then
        printf '\r  %s—%s  %-*s%s\n' "${_GRAY}" "${_CR}" "${_CHECK_W}" "${label}" \
            "${reason:+  ${_GRAY}${reason}${_CR}}" >&2
    else
        printf '  -  %-*s%s\n' "${_CHECK_W}" "${label}" "${reason:+  skipped}" >&2
    fi
}

_section()     { printf '\n%s%s%s\n' "${_BOLD}" "$*" "${_CR}" >&2; }
_result_ok()   { printf '\n  %s✓%s  %s\n' "${_BGREEN}" "${_CR}" "$*" >&2; }
_result_fail() {
    printf '\n  %s✗%s  %s\n' "${_BRED}" "${_CR}" "$1" >&2
    if [ -n "${2:-}" ]; then printf '     %s%s%s\n' "${_GRAY}" "$2" "${_CR}" >&2; fi
}

# ── rauc DBus last error ───────────────────────────────────────────────────────
_rauc_last_error() {
    command -v busctl >/dev/null 2>&1 || return 1
    busctl --system get-property de.pengutronix.rauc / \
        de.pengutronix.rauc.Installer LastError \
        2>/dev/null | sed -nE 's/^[^ ]+ "(.*)"$/\1/p'
}

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: iotgw-rauc-install [options] <bundle|url> [rauc install args...]

Wrapper for `rauc install` that handles certificate reconciliation, preflight
connectivity checks, /boot remounting, and visual progress display.

For HTTPS URLs, TLS config is read from /etc/rauc/system.conf [streaming].

Options:
  -n, --dry-run        Print planned actions and exit
  -v, --verbose        Show timestamped log output (disables visual UX)
  --no-systemd-run     Skip systemd-run dispatch (debugging only)
  -h, --help           Show this help

Internal:
  --direct             Used by systemd-run re-exec; skips outer dispatch
EOF
    exit 2
}

# ── URL parsing ───────────────────────────────────────────────────────────────
# Extracts URL_HOST and URL_PORT from an http(s):// URL.
_parse_url() {
    local rest hostport
    case "$1" in https://*) URL_PORT="443" ;; http://*) URL_PORT="80" ;; *) return 1 ;; esac
    rest="${1#*://}"; hostport="${rest%%/*}"; hostport="${hostport##*@}"
    if [[ "${hostport}" == *:* ]]; then
        URL_HOST="${hostport%%:*}"; URL_PORT="${hostport##*:}"
    else
        URL_HOST="${hostport}"
    fi
    [ -n "${URL_HOST}" ]
}

# ── TLS config from system.conf ───────────────────────────────────────────────
# Reads tls-ca / tls-cert / tls-key from [streaming] section into TLS_* globals.
# Used only for the preflight curl check; rauc install reads system.conf natively.
_read_streaming_tls() {
    local conf="/etc/rauc/system.conf"
    [ -r "${conf}" ] || return 1
    local vals
    vals="$(awk -F'[[:space:]]*=[[:space:]]*' '
        /^\[streaming\]/   { in_s=1; next }
        /^\[/              { in_s=0 }
        in_s && NF==2 && $1=="tls-ca"   { print "TLS_CA="$2 }
        in_s && NF==2 && $1=="tls-cert" { print "TLS_CERT="$2 }
        in_s && NF==2 && $1=="tls-key"  { print "TLS_KEY="$2 }
    ' "${conf}" 2>/dev/null)"
    TLS_CA="$(printf '%s\n'   "${vals}" | sed -n 's/^TLS_CA=//p')"
    TLS_CERT="$(printf '%s\n' "${vals}" | sed -n 's/^TLS_CERT=//p')"
    TLS_KEY="$(printf '%s\n'  "${vals}" | sed -n 's/^TLS_KEY=//p')"
    [ -n "${TLS_CA}" ] && [ -n "${TLS_CERT}" ] && [ -n "${TLS_KEY}" ]
}

# ── ota-certs-provision ───────────────────────────────────────────────────────
_reconcile_ota_certs() {
    local label="OTA certificates" rc=0
    _spin_start "${label}"
    _log "cert-reconcile starting"

    if command -v systemctl >/dev/null 2>&1 \
            && systemctl cat ota-certs-provision.service >/dev/null 2>&1; then
        if systemctl restart ota-certs-provision.service; then
            _log "cert-reconcile ok method=systemd"
            _check_ok "${label}"
            return 0
        fi
        rc=$?
    elif [ -x /usr/sbin/ota-certs-provision ]; then
        if /usr/sbin/ota-certs-provision >/dev/null 2>&1; then
            _log "cert-reconcile ok method=direct"
            _check_ok "${label}"
            return 0
        fi
        rc=$?
    else
        rc=127
    fi

    _log "cert-reconcile failed rc=${rc}"
    _check_fail "${label}" "rc=${rc}"
    return 1
}

# ── preflight connectivity check ──────────────────────────────────────────────
# Single mTLS curl against the bundle URL — verifies TCP, TLS handshake, and
# full CA chain in one shot.  TLS config is read from system.conf [streaming].
_preflight_url() {
    local label="Server  ${URL_HOST}:${URL_PORT}" curl_rc=0
    local key_is_uri=0
    local key_is_handle=0
    local key_for_curl="${TLS_KEY}"
    local -a key_opts=(--key "${TLS_KEY}")

    command -v curl >/dev/null 2>&1 || die "curl not found"
    _read_streaming_tls \
        || die "cannot read TLS config from /etc/rauc/system.conf [streaming]"

    for f in "${TLS_CA}" "${TLS_CERT}"; do
        [ -r "${f}" ] || { _check_fail "${label}" "missing: $(basename "${f}")"; return 1; }
    done
    if [[ "${TLS_KEY}" == *:* ]]; then
        key_is_uri=1
        if [[ "${TLS_KEY}" =~ ^handle:(0x[0-9A-Fa-f]+)$ ]]; then
            key_is_handle=1
            key_for_curl="${BASH_REMATCH[1]}"
            key_opts=(--engine tpm2tss --key-type ENG --key "${key_for_curl}")
        fi
    elif [ ! -r "${TLS_KEY}" ]; then
        _check_fail "${label}" "missing: $(basename "${TLS_KEY}")"
        return 1
    fi

    _spin_start "${label}"
    _log "preflight connect starting host=${URL_HOST} port=${URL_PORT}"
    [ "${key_is_uri}" -eq 1 ] && _log "preflight using key URI from system.conf"
    [ "${key_is_handle}" -eq 1 ] && _log "preflight using tpm2tss engine key=${key_for_curl}"

    if curl --fail --silent --show-error --location \
            --output /dev/null \
            --connect-timeout 5 --max-time 15 \
            --range 0-0 \
            --cacert "${TLS_CA}" --cert "${TLS_CERT}" \
            "${key_opts[@]}" \
            "${BUNDLE_INPUT}" >/dev/null 2>&1; then
        _log "preflight connect ok"
        _check_ok "${label}"
        return 0
    else
        curl_rc=$?
    fi
    _log "preflight connect failed curl_rc=${curl_rc}"
    _check_fail "${label}" "curl_rc=${curl_rc}"
    return 1
}

# ── mount state restore (EXIT trap) ───────────────────────────────────────────
_restore_mount_state() {
    local rc="$?"
    _spin_stop 2>/dev/null || true

    if [ "${MOUNTED_BY_US}" -eq 1 ]; then
        if [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] \
                && mountpoint -q "${BOOT_MP}"; then
            mount -o remount,ro "${BOOT_MP}" || true
        fi
        umount "${BOOT_MP}" 2>/dev/null || true
    elif [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] \
            && mountpoint -q "${BOOT_MP}"; then
        mount -o remount,ro "${BOOT_MP}" || true
    fi

    _log "completed rc=${rc}"
    if [ "${rc}" -eq 0 ]; then
        _result_ok "OTA install complete"
    else
        _result_fail "OTA install failed" "exit code ${rc}"
    fi
    exit "${rc}"
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        --direct)         DIRECT_MODE=1;    shift ;;
        --no-systemd-run) NO_SYSTEMD_RUN=1; shift ;;
        -n|--dry-run)     DRY_RUN=1;        shift ;;
        -v|--verbose)     VERBOSE=1;        shift ;;
        -h|--help)        usage ;;
        --)               shift; break ;;
        -*)               die "unknown option: $1" ;;
        *)                break ;;
    esac
done

[ "$#" -ge 1 ]            || usage
command -v rauc       >/dev/null 2>&1 || die "rauc not found"
command -v mountpoint >/dev/null 2>&1 || die "mountpoint not found"
command -v findmnt    >/dev/null 2>&1 || die "findmnt not found"

BUNDLE_INPUT="$1"; shift
EXTRA_ARGS=("$@")

case "${BUNDLE_INPUT}" in
    http://*|https://*) IS_URL=1 ;;
    *)                  IS_URL=0 ;;
esac

if [ "${IS_URL}" -eq 1 ]; then
    _parse_url "${BUNDLE_INPUT}" || die "invalid bundle URL '${BUNDLE_INPUT}'"
    [ "${BUNDLE_INPUT}" = "${BUNDLE_INPUT#http://}" ] \
        || die "only https:// URLs are supported"
fi

# Detect if /boot remount is needed (only when fw_env.config targets /boot)
if [ -r /etc/fw_env.config ]; then
    fw_env_target="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' /etc/fw_env.config || true)"
    case "${fw_env_target:-}" in
        /boot/*) BOOT_RW_REQUIRED=1 ;;
        *)       BOOT_RW_REQUIRED=0 ;;
    esac
fi

# ── outer dispatch via systemd-run ───────────────────────────────────────────
# Re-exec under systemd-run for consistent namespace/capability semantics
# regardless of how the operator invoked us (SSH, serial, cloud agent).
if [ "${DIRECT_MODE}" -eq 0 ] && [ "${NO_SYSTEMD_RUN}" -eq 0 ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        unit="iotgw-rauc-install-${RUN_ID}"
        reexec=(/usr/sbin/iotgw-rauc-install --direct)
        [ "${DRY_RUN}" -eq 1 ] && reexec+=(--dry-run)
        [ "${VERBOSE}" -eq 1 ] && reexec+=(--verbose)
        reexec+=("${BUNDLE_INPUT}" "${EXTRA_ARGS[@]}")

        rw_props=(--property=ReadWritePaths=/run)
        [ "${BOOT_RW_REQUIRED}" -eq 1 ] && rw_props+=(--property=ReadWritePaths="${BOOT_MP}")
        case "${fw_env_target:-}" in
            /boot/*|/uboot-env/*)
                rw_props+=(--property=ReadWritePaths="$(dirname "${fw_env_target}")")
                ;;
        esac

        _log "dispatching via systemd-run unit=${unit}"
        if [ "${VERBOSE}" -eq 0 ]; then
            printf '\n%sOTA Install%s\n  %s%s%s\n' \
                "${_BOLD}" "${_CR}" "${_GRAY}" "${BUNDLE_INPUT}" "${_CR}" >&2
        fi

        # On Ctrl-C / SIGTERM: cancel the rauc daemon install first (killing the
        # rauc-install client alone does NOT abort the daemon — it keeps going).
        # Then stop our transient unit.  systemd-run --wait does not forward signals.
        trap '
            printf "\n" >&2
            _log "cancelled — requesting rauc Cancel"
            busctl call de.pengutronix.rauc / de.pengutronix.rauc.Installer Cancel 2>/dev/null || true
            systemctl stop "${unit}" 2>/dev/null || true
            exit 130
        ' INT TERM

        if systemd-run --quiet --wait --collect --pipe \
                --unit "${unit}" \
                --property=NoNewPrivileges=yes \
                --property=PrivateTmp=yes \
                --property=PrivateMounts=no \
                --property=ProtectSystem=full \
                --property=ProtectHome=yes \
                --property=ProtectKernelTunables=yes \
                --property=ProtectKernelModules=yes \
                --property=ProtectKernelLogs=yes \
                --property=ProtectControlGroups=yes \
                --property=RestrictNamespaces=yes \
                --property=RestrictSUIDSGID=yes \
                --property=LockPersonality=yes \
                --property=MemoryDenyWriteExecute=yes \
                --property=PrivateUsers=no \
                "--property=RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
                "${rw_props[@]}" \
                "${reexec[@]}"; then
            trap - INT TERM
            exit 0
        else
            _rc=$?
            trap - INT TERM
            exit "${_rc}"
        fi
    fi
    _log "systemd-run not available; running direct"
fi

# EXIT only — INT/TERM use bash default (exit with 130/143), which triggers EXIT.
# Registering the same handler for TERM+EXIT causes double-invocation when the
# TERM handler calls `exit`, making the second EXIT run see $?=0 (false success).
trap _restore_mount_state EXIT

if [ "${VERBOSE}" -eq 0 ] && [ "${DIRECT_MODE}" -eq 0 ]; then
    printf '\n%sOTA Install%s\n  %s%s%s\n' \
        "${_BOLD}" "${_CR}" "${_GRAY}" "${BUNDLE_INPUT}" "${_CR}" >&2
fi

# ── preflight (HTTPS only) ────────────────────────────────────────────────────
if [ "${IS_URL}" -eq 1 ] && [ "${DRY_RUN}" -eq 0 ]; then
    _section "Preflight  ${URL_HOST}:${URL_PORT}"
    _reconcile_ota_certs || die "OTA certificate reconciliation failed"
    _preflight_url        || die "server not reachable: ${URL_HOST}:${URL_PORT}"
fi

# ── /boot remount ─────────────────────────────────────────────────────────────
if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
    if mountpoint -q "${BOOT_MP}"; then
        if findmnt -no OPTIONS "${BOOT_MP}" | grep -qw ro; then RO_BEFORE=1; fi
    else
        mount "${BOOT_MP}" || die "failed to mount ${BOOT_MP}"
        MOUNTED_BY_US=1
    fi
    if [ "${DRY_RUN}" -eq 0 ]; then
        mount -o remount,rw "${BOOT_MP}" || die "failed to remount ${BOOT_MP} rw"
        REMOUNTED_RW=1
        _log "remounted ${BOOT_MP} rw"
    fi
fi

# ── dry-run ───────────────────────────────────────────────────────────────────
if [ "${DRY_RUN}" -eq 1 ]; then
    printf '  %swould run:%s rauc install %s\n' \
        "${_GRAY}" "${_CR}" "${BUNDLE_INPUT}" >&2
    [ "${BOOT_RW_REQUIRED}" -eq 1 ] \
        && printf '  %swould remount%s %s rw\n' "${_GRAY}" "${_CR}" "${BOOT_MP}" >&2
    exit 0
fi

# ── rauc install ──────────────────────────────────────────────────────────────
# TLS for HTTPS streaming is handled by rauc natively via system.conf [streaming].
_section "Installing"
_log "rauc install starting bundle='${BUNDLE_INPUT}'"

rauc_cmd=(rauc install "${BUNDLE_INPUT}" "${EXTRA_ARGS[@]}")

if [ "${VERBOSE}" -eq 1 ]; then
    # Verbose: rauc output flows through directly; operator sees raw progress.
    if ! "${rauc_cmd[@]}"; then
        INSTALL_RC=$?
        _log "rauc install failed rc=${INSTALL_RC}"
        exit "${INSTALL_RC}"
    fi
elif [ "${IS_TTY}" -eq 1 ]; then
    # TTY normal: background spinner (continuous) + awk updates label from rauc output.
    # Spinner animates at fixed 0.2s rate; label shows current phase/percentage.
    # During silent phases (e.g. delta hash build) spinner keeps going, label holds last value.
    _bname="$(basename "${BUNDLE_INPUT}")"
    _pfile="$(mktemp)"
    printf '%s' "${_bname}" > "${_pfile}"

    (   chars='-/|'; i=0
        trap 'exit 0' TERM INT
        while true; do
            label="$(cat "${_pfile}" 2>/dev/null || printf '%s' "${_bname}")"
            printf '\r\033[K  %s%s%s  %s' "${_CYAN}" "${chars:$(( i % 3 )):1}" "${_CR}" "${label}" >&2
            sleep 0.2
            i=$(( i + 1 ))
        done
    ) &
    _SPIN_PID=$!

    set +e
    "${rauc_cmd[@]}" 2>&1 | awk \
        -v pfile="${_pfile}" -v bname="${_bname}" '
    BEGIN { pct=0; phase=bname }
    /^[[:space:]]*installing[[:space:]]*$/ { next }
    /\(installing:/ {
        s=$0; sub(/^.*\(installing:[[:space:]]*/,"",s)
        pct=int(s); sub(/^[0-9]+%\)[[:space:]]*/,"",s)
        if (s!="") { phase=s; gsub(/[[:space:]]+$/,"",phase) }
        printf "[%3d%%]  %s", pct, phase > pfile; close(pfile)
        next
    }
    /^[[:space:]]*[0-9]+%/ {
        s=$0; sub(/^[[:space:]]*/,"",s)
        pct=int(s); sub(/^[0-9]+%[[:space:]]*/,"",s)
        if (s!="") { phase=s; gsub(/[[:space:]]+$/,"",phase) }
        printf "[%3d%%]  %s", pct, phase > pfile; close(pfile)
        next
    }
    ' >/dev/null
    _pipe_status=("${PIPESTATUS[@]}")
    set -e
    _spin_stop
    printf '\n' >&2
    rm -f "${_pfile}"
    INSTALL_RC="${_pipe_status[0]}"
    if [ "${INSTALL_RC}" -ne 0 ]; then
        err="$(_rauc_last_error 2>/dev/null || true)"
        [ -n "${err}" ] && _log "rauc LastError=${err}"
        _log "rauc install failed rc=${INSTALL_RC}"
        exit "${INSTALL_RC}"
    fi
else
    # Non-TTY (automated): completely silent; syslog and rauc event log have the record.
    if ! "${rauc_cmd[@]}" >/dev/null 2>&1; then
        INSTALL_RC=$?
        err="$(_rauc_last_error 2>/dev/null || true)"
        [ -n "${err}" ] && _log "rauc LastError=${err}"
        _log "rauc install failed rc=${INSTALL_RC}"
        exit "${INSTALL_RC}"
    fi
fi

INSTALL_RC=0
_log "rauc install succeeded"
