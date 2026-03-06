#!/usr/bin/env bash
set -euo pipefail

BOOT_MP="/boot"
MOUNTED_BEFORE=0
RO_BEFORE=0
MOUNTED_BY_US=0
REMOUNTED_RW=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INSTALL_RC=0
DRY_RUN=0
DIRECT_MODE=0
DISPATCHED_MODE=0
BOOT_RW_REQUIRED=1
DEBUG_UNSAFE=0
TLS_INSECURE=0
ALLOW_MISSING_OTA_USER=0
FALLBACK_DOWNLOAD=0
TLS_PROFILE="system"
IS_URL=0
INSTALL_SOURCE=""
DOWNLOAD_TMP=""
PREFLIGHT_STAGE=""
PREFLIGHT_MSG=""
TLS_CA=""
TLS_CERT=""
TLS_KEY=""
URL_HOST=""
URL_PORT=""
URL_SCHEME=""
URL_PATH=""
BUNDLE_INPUT=""
EXTRA_ARGS=()
SYSTEMD_DISPATCH_RW_PATHS=()

log() { printf '[iotgw-rauc-install] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
audit() {
    local msg="$*"
    log "run=${RUN_ID} ${msg}"
    if command -v logger >/dev/null 2>&1; then
        logger -t iotgw-rauc-install "run=${RUN_ID} ${msg}" || true
    fi
}

rauc_dbus_get_last_error() {
    if ! command -v busctl >/dev/null 2>&1; then
        return 1
    fi
    busctl --system get-property \
        de.pengutronix.rauc \
        / \
        de.pengutronix.rauc.Installer \
        LastError 2>/dev/null | sed -nE 's/^[^ ]+ "(.*)"$/\1/p'
}

usage() {
    cat >&2 <<'EOF'
Usage: iotgw-rauc-install [wrapper options] <bundle|url> [rauc install args...]

Wrapper for `rauc install` that temporarily remounts /boot read-write so
fw_setenv-backed bootloader updates succeed, then restores prior mount state.
If `/etc/fw_env.config` does not point into `/boot`, remount is skipped.

By default, it dispatches itself through `systemd-run` for consistent
privilege/mount namespace semantics on hardened systems.

Wrapper options:
  --direct                  Run install path directly (no dispatch)
  --no-systemd-run          Disable systemd-run dispatch
  -n, --n, --dry-run        Print planned actions and exit
  --tls-profile <name>      TLS profile for HTTPS URLs: system|data (default: system)
  --fallback-download       On HTTPS preflight failure, download bundle then install local file
  --debug-unsafe            Allow explicitly unsafe debug-only flags
  --tls-insecure            Disable TLS peer verification (requires --debug-unsafe)
  --allow-missing-ota-user  Continue if streaming sandbox-user does not exist (requires --debug-unsafe)
EOF
    exit 2
}

append_dispatch_rw_path() {
    local path="$1"
    local existing
    [ -n "${path}" ] || return 0
    for existing in "${SYSTEMD_DISPATCH_RW_PATHS[@]}"; do
        [ "${existing}" = "${path}" ] && return 0
    done
    SYSTEMD_DISPATCH_RW_PATHS+=("${path}")
}

build_dispatch_rw_paths() {
    local fw_env_dir=""
    SYSTEMD_DISPATCH_RW_PATHS=()

    # RAUC/runtime state and journald IPC can touch /run.
    append_dispatch_rw_path "/run"

    # Fallback download stores bundle in /tmp before local install.
    if [ "${FALLBACK_DOWNLOAD}" -eq 1 ]; then
        append_dispatch_rw_path "/tmp"
    fi

    if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
        append_dispatch_rw_path "${BOOT_MP}"
    fi

    case "${fw_env_target:-}" in
        /boot/*|/uboot-env/*)
            fw_env_dir="$(dirname "${fw_env_target}")"
            append_dispatch_rw_path "${fw_env_dir}"
            ;;
    esac
}

detect_streaming_sandbox_user() {
    local conf="/etc/rauc/system.conf"
    if [ -r "${conf}" ]; then
        awk -F= '
            /^\[streaming\]/ { in_stream=1; next }
            /^\[/ { in_stream=0 }
            in_stream && $1 ~ /^[[:space:]]*sandbox-user[[:space:]]*$/ {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2
                exit
            }' "${conf}" 2>/dev/null || true
    fi
}

set_tls_profile_paths() {
    case "${TLS_PROFILE}" in
        system)
            TLS_CA="/etc/ota/ca.crt"
            TLS_CERT="/etc/ota/device.crt"
            TLS_KEY="/etc/ota/device.key"
            ;;
        data)
            TLS_CA="/data/ota-ca.crt"
            TLS_CERT="/data/ota-device.crt"
            TLS_KEY="/data/ota-device.key"
            ;;
        *)
            die "invalid --tls-profile '${TLS_PROFILE}' (expected: system|data)"
            ;;
    esac
}

parse_url_fields() {
    local input="$1"
    local rest auth_host path hostport

    URL_SCHEME=""
    URL_HOST=""
    URL_PORT=""
    URL_PATH=""

    case "${input}" in
        https://*)
            URL_SCHEME="https"
            URL_PORT="443"
            ;;
        http://*)
            URL_SCHEME="http"
            URL_PORT="80"
            ;;
        *)
            return 1
            ;;
    esac

    rest="${input#*://}"
    auth_host="${rest%%/*}"
    path="/${rest#*/}"
    [ "${rest}" = "${auth_host}" ] && path="/"
    hostport="${auth_host##*@}"

    if [[ "${hostport}" == *:* ]]; then
        URL_HOST="${hostport%%:*}"
        URL_PORT="${hostport##*:}"
    else
        URL_HOST="${hostport}"
    fi
    URL_PATH="${path}"

    [ -n "${URL_HOST}" ] || return 1
    [ -n "${URL_PORT}" ] || return 1
    return 0
}

preflight_fail() {
    PREFLIGHT_STAGE="$1"
    PREFLIGHT_MSG="$2"
    audit "stage=${PREFLIGHT_STAGE} status=failed reason='${PREFLIGHT_MSG}'"
    return 1
}

preflight_streaming_url() {
    local sandbox_user
    local file
    local curl_rc
    local curl_common=()
    local curl_cmd=()

    PREFLIGHT_STAGE=""
    PREFLIGHT_MSG=""
    set_tls_profile_paths

    audit "stage=resolve status=starting host=${URL_HOST}"
    if command -v getent >/dev/null 2>&1; then
        if getent ahostsv4 "${URL_HOST}" >/dev/null 2>&1 || getent ahosts "${URL_HOST}" >/dev/null 2>&1; then
            audit "stage=resolve status=ok host=${URL_HOST}"
        else
            preflight_fail "resolve" "host '${URL_HOST}' could not be resolved"
            return 1
        fi
    else
        audit "stage=resolve status=skipped reason='getent unavailable'"
    fi

    sandbox_user="$(detect_streaming_sandbox_user)"
    if [ -n "${sandbox_user}" ]; then
        audit "stage=user-check status=starting user=${sandbox_user}"
        if id -u "${sandbox_user}" >/dev/null 2>&1; then
            audit "stage=user-check status=ok user=${sandbox_user}"
        elif [ "${ALLOW_MISSING_OTA_USER}" -eq 1 ]; then
            audit "stage=user-check status=warn user=${sandbox_user} reason='missing user accepted by debug override'"
        else
            preflight_fail "user-check" "streaming sandbox-user '${sandbox_user}' not found (use --debug-unsafe --allow-missing-ota-user only for triage)"
            return 1
        fi
    else
        audit "stage=user-check status=skipped reason='no sandbox-user in /etc/rauc/system.conf'"
    fi

    audit "stage=tls-files status=starting profile=${TLS_PROFILE}"
    for file in "${TLS_CA}" "${TLS_CERT}" "${TLS_KEY}"; do
        if [ ! -r "${file}" ]; then
            preflight_fail "tls-files" "required TLS file is missing/unreadable: ${file}"
            return 1
        fi
    done
    audit "stage=tls-files status=ok profile=${TLS_PROFILE}"

    command -v curl >/dev/null 2>&1 || preflight_fail "connect" "curl command not found"
    [ -n "${PREFLIGHT_STAGE}" ] && return 1

    curl_common=(
        --fail
        --location
        --silent
        --show-error
        --output /dev/null
        --connect-timeout 5
        --max-time 15
        --range 0-0
        --cert "${TLS_CERT}"
        --key "${TLS_KEY}"
    )

    audit "stage=connect status=starting host=${URL_HOST} port=${URL_PORT}"
    curl_cmd=(curl "${curl_common[@]}" --insecure "${BUNDLE_INPUT}")
    if "${curl_cmd[@]}" >/dev/null 2>&1; then
        audit "stage=connect status=ok host=${URL_HOST} port=${URL_PORT}"
    else
        curl_rc=$?
        preflight_fail "connect" "failed to connect to ${URL_HOST}:${URL_PORT} or perform TLS handshake (curl_rc=${curl_rc})"
        return 1
    fi

    if [ "${TLS_INSECURE}" -eq 1 ]; then
        audit "stage=tls-verify status=skipped reason='--tls-insecure enabled'"
        return 0
    fi

    audit "stage=tls-verify status=starting profile=${TLS_PROFILE}"
    curl_cmd=(curl "${curl_common[@]}" --cacert "${TLS_CA}" "${BUNDLE_INPUT}")
    if "${curl_cmd[@]}" >/dev/null 2>&1; then
        audit "stage=tls-verify status=ok profile=${TLS_PROFILE}"
        return 0
    else
        curl_rc=$?
        preflight_fail "tls-verify" "peer verification failed (CA/SAN/hostname mismatch or certificate chain error, curl_rc=${curl_rc})"
        return 1
    fi
}

download_streaming_bundle() {
    local curl_cmd=()
    DOWNLOAD_TMP="/tmp/iotgw-rauc-install-${RUN_ID}.raucb"
    set_tls_profile_paths

    audit "stage=fallback-download status=starting target=${DOWNLOAD_TMP}"
    if [ "${TLS_INSECURE}" -eq 1 ]; then
        curl_cmd=(curl --fail --silent --show-error --location --retry 2 --connect-timeout 5 --max-time 900 --insecure --cert "${TLS_CERT}" --key "${TLS_KEY}" --output "${DOWNLOAD_TMP}" "${BUNDLE_INPUT}")
    else
        curl_cmd=(curl --fail --silent --show-error --location --retry 2 --connect-timeout 5 --max-time 900 --cacert "${TLS_CA}" --cert "${TLS_CERT}" --key "${TLS_KEY}" --output "${DOWNLOAD_TMP}" "${BUNDLE_INPUT}")
    fi

    if "${curl_cmd[@]}"; then
        audit "stage=fallback-download status=ok target=${DOWNLOAD_TMP}"
        INSTALL_SOURCE="${DOWNLOAD_TMP}"
        return 0
    fi

    audit "stage=fallback-download status=failed target=${DOWNLOAD_TMP}"
    return 1
}

restore_mount_state() {
    local rc="$?"

    if [ -n "${DOWNLOAD_TMP}" ] && [ -f "${DOWNLOAD_TMP}" ]; then
        rm -f "${DOWNLOAD_TMP}" || true
    fi

    if [ "${MOUNTED_BY_US}" -eq 1 ]; then
        if [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] && mountpoint -q "${BOOT_MP}"; then
            mount -o remount,ro "${BOOT_MP}" || true
            audit "restored /boot to ro (wrapper-mounted case)"
        fi
        umount "${BOOT_MP}" || true
        audit "unmounted /boot (wrapper-mounted case), install_rc=${INSTALL_RC}, exit_rc=${rc}"
        exit "${rc}"
    fi

    if [ "${RO_BEFORE}" -eq 1 ] && [ "${REMOUNTED_RW}" -eq 1 ] && mountpoint -q "${BOOT_MP}"; then
        mount -o remount,ro "${BOOT_MP}" || true
        audit "restored /boot to ro"
    fi

    audit "completed install_rc=${INSTALL_RC}, exit_rc=${rc}"
    exit "${rc}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --direct)
            DIRECT_MODE=1
            shift
            ;;
        --no-systemd-run)
            DISPATCHED_MODE=1
            shift
            ;;
        --tls-profile)
            [ "$#" -ge 2 ] || die "--tls-profile requires an argument"
            TLS_PROFILE="$2"
            shift 2
            ;;
        --fallback-download)
            FALLBACK_DOWNLOAD=1
            shift
            ;;
        --debug-unsafe)
            DEBUG_UNSAFE=1
            shift
            ;;
        --tls-insecure)
            TLS_INSECURE=1
            shift
            ;;
        --allow-missing-ota-user)
            ALLOW_MISSING_OTA_USER=1
            shift
            ;;
        -n|--n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -ge 1 ] || usage
command -v rauc >/dev/null 2>&1 || die "rauc command not found"
command -v mountpoint >/dev/null 2>&1 || die "mountpoint command not found"
command -v findmnt >/dev/null 2>&1 || die "findmnt command not found"
BUNDLE_INPUT="$1"
shift
EXTRA_ARGS=("$@")

case "${BUNDLE_INPUT}" in
    http://*|https://*)
        IS_URL=1
        ;;
    *)
        IS_URL=0
        ;;
esac

if [ "${IS_URL}" -eq 1 ]; then
    parse_url_fields "${BUNDLE_INPUT}" || die "invalid bundle URL '${BUNDLE_INPUT}'"
    if [ "${URL_SCHEME}" != "https" ] && [ "${DEBUG_UNSAFE}" -ne 1 ]; then
        die "only https:// bundle URLs are supported (use --debug-unsafe to bypass for diagnostics)"
    fi
fi

if [ "${TLS_INSECURE}" -eq 1 ] || [ "${ALLOW_MISSING_OTA_USER}" -eq 1 ]; then
    [ "${DEBUG_UNSAFE}" -eq 1 ] || die "--tls-insecure/--allow-missing-ota-user require --debug-unsafe"
fi

if [ "${TLS_INSECURE}" -eq 1 ]; then
    audit "UNSAFE debug mode enabled: TLS peer verification disabled"
fi

for arg in "${EXTRA_ARGS[@]}"; do
    case "${arg}" in
        --tls-ca|--tls-cert|--tls-key|--tls-no-verify)
            if [ "${DEBUG_UNSAFE}" -ne 1 ]; then
                die "manual '${arg}' is blocked; use --tls-profile (or --debug-unsafe for manual TLS debug)"
            fi
            ;;
    esac
done

if [ -r /etc/fw_env.config ]; then
    fw_env_target="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' /etc/fw_env.config || true)"
    case "${fw_env_target}" in
        /boot/*)
            BOOT_RW_REQUIRED=1
            ;;
        *)
            BOOT_RW_REQUIRED=0
            ;;
    esac
fi

if [ "${DIRECT_MODE}" -eq 1 ]; then
    audit "systemd-run dispatch bypassed: --direct"
elif [ "${DISPATCHED_MODE}" -eq 1 ]; then
    audit "systemd-run dispatch bypassed: --no-systemd-run"
fi

# Prefer executing from systemd manager context to avoid hardened SSH session
# namespace/capability differences from rauc.service.
if [ "${DIRECT_MODE}" -eq 0 ] && [ "${DISPATCHED_MODE}" -eq 0 ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        local_rw_paths=""
        systemd_props=()
        unit="iotgw-rauc-install-${RUN_ID}"
        reexec=(/usr/sbin/iotgw-rauc-install --direct)
        build_dispatch_rw_paths
        for path in "${SYSTEMD_DISPATCH_RW_PATHS[@]}"; do
            local_rw_paths="${local_rw_paths:+${local_rw_paths} }${path}"
        done
        systemd_props=(
            "--property=NoNewPrivileges=yes"
            "--property=PrivateTmp=yes"
            "--property=PrivateMounts=no"
            "--property=ProtectSystem=full"
            "--property=ProtectHome=yes"
            "--property=ProtectKernelTunables=yes"
            "--property=ProtectKernelModules=yes"
            "--property=ProtectKernelLogs=yes"
            "--property=ProtectControlGroups=yes"
            "--property=RestrictNamespaces=yes"
            "--property=RestrictSUIDSGID=yes"
            "--property=LockPersonality=yes"
            "--property=MemoryDenyWriteExecute=yes"
            "--property=PrivateUsers=no"
            "--property=RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"
        )
        for path in "${SYSTEMD_DISPATCH_RW_PATHS[@]}"; do
            systemd_props+=("--property=ReadWritePaths=${path}")
        done
        [ "${DRY_RUN}" -eq 1 ] && reexec+=(--dry-run)
        [ "${TLS_PROFILE}" != "system" ] && reexec+=(--tls-profile "${TLS_PROFILE}")
        [ "${FALLBACK_DOWNLOAD}" -eq 1 ] && reexec+=(--fallback-download)
        [ "${DEBUG_UNSAFE}" -eq 1 ] && reexec+=(--debug-unsafe)
        [ "${TLS_INSECURE}" -eq 1 ] && reexec+=(--tls-insecure)
        [ "${ALLOW_MISSING_OTA_USER}" -eq 1 ] && reexec+=(--allow-missing-ota-user)
        reexec+=("${BUNDLE_INPUT}" "${EXTRA_ARGS[@]}")
        audit "dispatching via systemd-run unit=${unit} profile=namespace-hardened rw_paths='${local_rw_paths}'"
        if systemd-run \
            --quiet \
            --wait \
            --collect \
            --pipe \
            --unit "${unit}" \
            "${systemd_props[@]}" \
            "${reexec[@]}"; then
            INSTALL_RC=0
            audit "systemd-run install succeeded"
            exit 0
        else
            INSTALL_RC=$?
            audit "systemd-run install failed rc=${INSTALL_RC}"
            exit "${INSTALL_RC}"
        fi
    fi
    audit "systemd-run not available; continuing direct"
fi

trap restore_mount_state EXIT INT TERM

INSTALL_SOURCE="${BUNDLE_INPUT}"
if [ "${IS_URL}" -eq 1 ] && [ "${URL_SCHEME}" = "https" ]; then
    set_tls_profile_paths
    if [ "${DRY_RUN}" -eq 1 ]; then
        audit "preflight status=skipped reason='dry-run'"
    elif preflight_streaming_url; then
        audit "preflight status=ok profile=${TLS_PROFILE} host=${URL_HOST}"
    else
        if [ "${FALLBACK_DOWNLOAD}" -eq 1 ]; then
            audit "preflight status=failed stage=${PREFLIGHT_STAGE} fallback=download"
            download_streaming_bundle || die "fallback download failed after preflight stage=${PREFLIGHT_STAGE}"
        else
            die "preflight failed stage=${PREFLIGHT_STAGE}: ${PREFLIGHT_MSG}"
        fi
    fi
fi

if [ "${IS_URL}" -eq 1 ] && [ "${URL_SCHEME}" != "https" ]; then
    audit "preflight status=skipped reason='non-https URL'"
fi

if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
    if mountpoint -q "${BOOT_MP}"; then
        MOUNTED_BEFORE=1
    else
        mount "${BOOT_MP}" || die "failed to mount ${BOOT_MP}"
        MOUNTED_BY_US=1
    fi

    if [ "${MOUNTED_BEFORE}" -eq 1 ] || [ "${MOUNTED_BY_US}" -eq 1 ]; then
        if findmnt -no OPTIONS "${BOOT_MP}" | grep -qw ro; then
            RO_BEFORE=1
        fi
    fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    audit "dry-run bundle='${INSTALL_SOURCE}' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
    if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
        audit "dry-run would remount ${BOOT_MP} rw"
    else
        audit "dry-run: /boot remount not required (fw_env.config target='${fw_env_target:-unknown}')"
    fi
    if [ "${IS_URL}" -eq 1 ] && [ "${URL_SCHEME}" = "https" ] && [ "${INSTALL_SOURCE}" = "${BUNDLE_INPUT}" ]; then
        if [ "${TLS_INSECURE}" -eq 1 ]; then
            audit "dry-run would run: rauc install --tls-no-verify --tls-cert '${TLS_CERT}' --tls-key '${TLS_KEY}' '${INSTALL_SOURCE}' ${EXTRA_ARGS[*]}"
        else
            audit "dry-run would run: rauc install --tls-ca '${TLS_CA}' --tls-cert '${TLS_CERT}' --tls-key '${TLS_KEY}' '${INSTALL_SOURCE}' ${EXTRA_ARGS[*]}"
        fi
    else
        audit "dry-run would run: rauc install '${INSTALL_SOURCE}' ${EXTRA_ARGS[*]}"
    fi
    INSTALL_RC=0
    exit 0
fi

audit "starting bundle='${INSTALL_SOURCE}' mounted_before=${MOUNTED_BEFORE} ro_before=${RO_BEFORE}"
if [ "${BOOT_RW_REQUIRED}" -eq 1 ]; then
    mount -o remount,rw "${BOOT_MP}" || die "failed to remount ${BOOT_MP} rw"
    REMOUNTED_RW=1
    audit "remounted /boot rw"
else
    audit "/boot remount skipped (fw_env.config target='${fw_env_target:-unknown}')"
fi

audit "running rauc install"
if [ "${IS_URL}" -eq 1 ] && [ "${URL_SCHEME}" = "https" ] && [ "${INSTALL_SOURCE}" = "${BUNDLE_INPUT}" ]; then
    if [ "${TLS_INSECURE}" -eq 1 ]; then
        rauc_cmd=(rauc install --tls-no-verify --tls-cert "${TLS_CERT}" --tls-key "${TLS_KEY}" "${INSTALL_SOURCE}" "${EXTRA_ARGS[@]}")
    else
        rauc_cmd=(rauc install --tls-ca "${TLS_CA}" --tls-cert "${TLS_CERT}" --tls-key "${TLS_KEY}" "${INSTALL_SOURCE}" "${EXTRA_ARGS[@]}")
    fi
else
    rauc_cmd=(rauc install "${INSTALL_SOURCE}" "${EXTRA_ARGS[@]}")
fi
# Filter rauc progress output: print on phase change or stage completion,
# suppress repeated percentage lines for the same message.
# set -o pipefail (active) ensures the pipeline exit reflects rauc's exit code.
if "${rauc_cmd[@]}" 2>&1 | awk '
    /^[[:space:]]*[0-9]+%/ {
        pct = $1 + 0
        sub(/^[[:space:]]*[0-9]+%[[:space:]]*/, "")
        msg = $0
        if (msg != last_msg || msg ~ /done\.$/ || pct == 100) {
            printf "[%3d%%] %s\n", pct, msg
            last_msg = msg
        }
        next
    }
    { print }
'; then
    INSTALL_RC=0
    audit "rauc install succeeded"
else
    INSTALL_RC=$?
    if rauc_last_error="$(rauc_dbus_get_last_error || true)"; then
        if [ -n "${rauc_last_error}" ]; then
            audit "rauc dbus LastError='${rauc_last_error}'"
        fi
    fi
    audit "rauc install failed rc=${INSTALL_RC}"
    exit "${INSTALL_RC}"
fi
