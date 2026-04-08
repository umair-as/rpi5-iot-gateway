#!/bin/bash
set -euo pipefail

STAMP="/var/lib/iotgw-provision.done"
SRC_DIR="/data/iotgw"
OBS_DST="/etc/default/iotgw-observability"
UBOOT_POLICY="/etc/default/iotgw-uboot-policy"
OBS_CRED_DIR="/etc/credstore"
CHANGED=0
WARNINGS=0

RC_OK=0
RC_MOSQ_PASSWD_NOT_PERSISTED=40
RC_MOSQ_GROUP_MISSING=41
RC_MOSQ_USER_MISSING=42

NM_PROFILE_UPDATES=0
NM_CONF_UPDATES=0
OBS_SOURCE="none"
OBS_CRED_UPDATES=0
OBS_BROKER_APPLIED=0
LEGACY_SECRET_KEYS_REMOVED=0
UBOOT_ENV_UPDATES=0

mkdir -p /var/lib

log() { echo "$*" >&2; }
warn() {
    WARNINGS=$((WARNINGS + 1))
    log "⚠️  [provision] $*"
}
fail() {
    local code="$1"
    shift
    log "❌ [provision] $* (rc=${code})"
    exit "$code"
}
log "📦 [provision] Start: network + observability first-boot provisioning"

get_env_value() {
    local file="$1"
    local key="$2"
    sed -n "s/^${key}=//p" "$file" | tail -n 1
}

unset_env_key() {
    local file="$1"
    local key="$2"
    [ -e "$file" ] || return 1
    grep -q "^${key}=" "$file" || return 1

    tmp="$(mktemp "${file}.tmp.XXXXXX")"
    removed=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line#"${key}"=}" != "$line" ]; then
            removed=1
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    chmod --reference="$file" "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
    if [ "$removed" -eq 1 ]; then
        return 0
    fi
    return 1
}

set_credential_value() {
    local file="$1"
    local value="$2"
    local changed=0
    local current=""

    if [ -e "$file" ]; then
        current="$(cat "$file" 2>/dev/null || true)"
    fi
    if [ "$current" != "$value" ]; then
        printf '%s' "$value" > "$file"
        changed=1
    fi
    chmod 0600 "$file"
    chown root:root "$file" 2>/dev/null || true
    if [ "$changed" -eq 1 ]; then
        return 0
    fi
    return 1
}

get_fw_env_value() {
    local key="$1"
    local line
    line="$(fw_printenv "$key" 2>/dev/null | sed -n "s/^${key}=//p" | tail -n 1 || true)"
    printf '%s' "$line"
}

apply_uboot_policy() {
    local desired current

    [ -r "$UBOOT_POLICY" ] || return 0
    desired="$(get_env_value "$UBOOT_POLICY" "IOTGW_UBOOT_BOOTDELAY")"
    [ -n "$desired" ] || return 0

    if ! command -v fw_setenv >/dev/null 2>&1 || ! command -v fw_printenv >/dev/null 2>&1; then
        warn "U-Boot policy present but fw_setenv/fw_printenv unavailable; skipping bootdelay policy"
        return 0
    fi

    current="$(get_fw_env_value "bootdelay")"
    if [ "$current" = "$desired" ]; then
        log "ℹ️  [provision] U-Boot bootdelay already set to ${desired}"
        return 0
    fi

    if fw_setenv bootdelay "$desired"; then
        UBOOT_ENV_UPDATES=$((UBOOT_ENV_UPDATES + 1))
        CHANGED=1
        log "⚙️  [provision] Applied U-Boot bootdelay policy: ${current:-<unset>} -> ${desired}"
    else
        warn "Failed to apply U-Boot bootdelay policy (${desired})"
    fi
}

normalize_mosquitto_auth_files() {
    local changed=0
    if ! getent passwd mosquitto >/dev/null 2>&1; then
        fail "$RC_MOSQ_USER_MISSING" "required user 'mosquitto' is missing"
    fi
    if ! getent group mosquitto >/dev/null 2>&1; then
        fail "$RC_MOSQ_GROUP_MISSING" "required group 'mosquitto' is missing"
    fi

    install -d /etc/mosquitto
    if [ ! -e /etc/mosquitto/passwd ]; then
        install -m 0600 -o mosquitto -g mosquitto /dev/null /etc/mosquitto/passwd
        changed=1
    fi
    if [ ! -e /etc/mosquitto/acl ]; then
        install -m 0600 -o mosquitto -g mosquitto /dev/null /etc/mosquitto/acl
        changed=1
    fi

    if [ -e /etc/mosquitto/passwd ]; then
        cur_owner="$(stat -c '%U:%G' /etc/mosquitto/passwd 2>/dev/null || true)"
        if [ "$cur_owner" != "mosquitto:mosquitto" ]; then
            chown mosquitto:mosquitto /etc/mosquitto/passwd
            changed=1
        fi
        cur_mode="$(stat -c '%a' /etc/mosquitto/passwd 2>/dev/null || true)"
        if [ "$cur_mode" != "600" ]; then
            chmod 0600 /etc/mosquitto/passwd
            changed=1
        fi
    fi
    if [ -e /etc/mosquitto/acl ]; then
        cur_owner="$(stat -c '%U:%G' /etc/mosquitto/acl 2>/dev/null || true)"
        if [ "$cur_owner" != "mosquitto:mosquitto" ]; then
            chown mosquitto:mosquitto /etc/mosquitto/acl
            changed=1
        fi
        cur_mode="$(stat -c '%a' /etc/mosquitto/acl 2>/dev/null || true)"
        if [ "$cur_mode" != "600" ]; then
            chmod 0600 /etc/mosquitto/acl
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        log "[provision] Normalized mosquitto auth file ownership/mode"
    fi
}

# Data source directory is optional. If absent, provisioning inputs are skipped.
if [ ! -d "$SRC_DIR" ]; then
    log "ℹ️  [provision] No $SRC_DIR directory; skipping data-driven provisioning inputs"
fi

# Keep mosquitto auth material readable by the daemon account on every boot.
normalize_mosquitto_auth_files
apply_uboot_policy

# Exit early if already provisioned
if [ -e "$STAMP" ]; then
    log "✅ [provision] Already provisioned; nothing to do"
    exit 0
fi

# NetworkManager profiles and conf.d
if [ -d "$SRC_DIR/nm" ]; then
    log "🔍 [provision] Checking for .nmconnection files in $SRC_DIR/nm"
    install -d /etc/NetworkManager/system-connections
    copied=0
    for f in "$SRC_DIR"/nm/*.nmconnection; do
        [ -e "$f" ] || continue
        log "⚙️  [provision] Installing $(basename "$f")"
        install -m 0600 "$f" /etc/NetworkManager/system-connections/
        copied=1
        NM_PROFILE_UPDATES=$((NM_PROFILE_UPDATES + 1))
    done
    if [ "$copied" -eq 1 ]; then
        CHANGED=1
    fi

    if [ -d "$SRC_DIR/nm-conf" ]; then
        log "🔍 [provision] Checking for NetworkManager conf in $SRC_DIR/nm-conf"
        install -d /etc/NetworkManager/conf.d
        confcopied=0
        for c in "$SRC_DIR"/nm-conf/*.conf; do
            [ -e "$c" ] || continue
            log "⚙️  [provision] Installing conf $(basename "$c")"
            install -m 0644 "$c" /etc/NetworkManager/conf.d/
            confcopied=1
            NM_CONF_UPDATES=$((NM_CONF_UPDATES + 1))
        done
        if [ "$confcopied" -eq 1 ]; then
            CHANGED=1
        fi
    fi

    if command -v nmcli >/dev/null 2>&1; then
        log "🔄 [provision] Reloading NetworkManager connections"
        nmcli connection reload || true
    fi
else
    log "ℹ️  [provision] No $SRC_DIR/nm directory; skipping"
fi

# Observability credentials/bootstrap (authoritative source: /data).
OBS_SRC="$SRC_DIR/observability.env"
if [ -r "$OBS_SRC" ]; then
    OBS_SOURCE="$OBS_SRC"
    obs_secret_present=0
    obs_apply_ok=1
    mqtt_user="$(get_env_value "$OBS_SRC" "MQTT_USERNAME")"
    mqtt_pass="$(get_env_value "$OBS_SRC" "MQTT_PASSWORD")"
    influx_user="$(get_env_value "$OBS_SRC" "INFLUXDB_USERNAME")"
    influx_pass="$(get_env_value "$OBS_SRC" "INFLUXDB_PASSWORD")"

    install -d -m 0700 "$OBS_CRED_DIR"

    if [ -n "$mqtt_user" ]; then
        obs_secret_present=1
        if set_credential_value "$OBS_CRED_DIR/telegraf.service.mqtt_username" "$mqtt_user"; then
            CHANGED=1
            OBS_CRED_UPDATES=$((OBS_CRED_UPDATES + 1))
        fi
    fi
    if [ -n "$mqtt_pass" ]; then
        obs_secret_present=1
        if set_credential_value "$OBS_CRED_DIR/telegraf.service.mqtt_password" "$mqtt_pass"; then
            CHANGED=1
            OBS_CRED_UPDATES=$((OBS_CRED_UPDATES + 1))
        fi
    fi
    if [ -n "$influx_user" ]; then
        obs_secret_present=1
        if set_credential_value "$OBS_CRED_DIR/telegraf.service.influxdb_username" "$influx_user"; then
            CHANGED=1
            OBS_CRED_UPDATES=$((OBS_CRED_UPDATES + 1))
        fi
    fi
    if [ -n "$influx_pass" ]; then
        obs_secret_present=1
        if set_credential_value "$OBS_CRED_DIR/telegraf.service.influxdb_password" "$influx_pass"; then
            CHANGED=1
            OBS_CRED_UPDATES=$((OBS_CRED_UPDATES + 1))
        fi
    fi

    if [ -n "$mqtt_user" ] && [ -n "$mqtt_pass" ]; then
        if command -v mosquitto_passwd >/dev/null 2>&1; then
            install -d /etc/mosquitto
            touch /etc/mosquitto/acl
            chmod 0600 /etc/mosquitto/acl
            chown mosquitto:mosquitto /etc/mosquitto/acl

            # Use -c only when the file is absent or empty to avoid the
            # "Corrupt password file" error. When the file has existing
            # entries, omit -c so other users are preserved.
            # stdin: password\npassword\n (no -b avoids argv exposure)
            if [ ! -s /etc/mosquitto/passwd ]; then
                if ! printf '%s\n%s\n' "$mqtt_pass" "$mqtt_pass" | mosquitto_passwd -c /etc/mosquitto/passwd "$mqtt_user"; then
                    fail "$RC_MOSQ_PASSWD_NOT_PERSISTED" "mosquitto_passwd failed for user '${mqtt_user}'"
                fi
            else
                if ! printf '%s\n%s\n' "$mqtt_pass" "$mqtt_pass" | mosquitto_passwd /etc/mosquitto/passwd "$mqtt_user"; then
                    fail "$RC_MOSQ_PASSWD_NOT_PERSISTED" "mosquitto_passwd failed for user '${mqtt_user}'"
                fi
            fi
            chmod 0600 /etc/mosquitto/passwd
            chown mosquitto:mosquitto /etc/mosquitto/passwd
            if ! grep -q "^${mqtt_user}:" /etc/mosquitto/passwd; then
                fail "$RC_MOSQ_PASSWD_NOT_PERSISTED" "mosquitto_passwd did not persist user '${mqtt_user}'"
            fi
            if ! grep -q "^user ${mqtt_user}$" /etc/mosquitto/acl; then
                {
                    printf '\n'
                    printf 'user %s\n' "$mqtt_user"
                    printf 'topic read sensors/+/data\n'
                } >> /etc/mosquitto/acl
            fi

            CHANGED=1
            OBS_BROKER_APPLIED=1
            log "[provision] Applied MQTT credentials for telegraf/mosquitto (credstore + broker)"
        else
            warn "mosquitto_passwd not found; skipping MQTT credential provisioning"
            obs_apply_ok=0
        fi
    else
        log "ℹ️  [provision] $OBS_SRC found but MQTT credentials are empty; skipping"
    fi

    if [ "$obs_secret_present" -eq 1 ] && [ "$obs_apply_ok" -eq 1 ]; then
        obs_src_dir="$(dirname "$OBS_SRC")"
        if [ -w "$obs_src_dir" ] && rm -f "$OBS_SRC"; then
            CHANGED=1
            log "[provision] Removed bootstrap secret source: $OBS_SRC"
        elif [ ! -w "$obs_src_dir" ]; then
            log "ℹ️  [provision] $obs_src_dir not writable; bootstrap source cleanup deferred"
        else
            warn "Failed to remove bootstrap secret source: $OBS_SRC"
        fi
    elif [ "$obs_secret_present" -eq 1 ]; then
        warn "Bootstrap source retained due to incomplete credential apply"
    fi
fi

# Migrate away from env-file stored secrets if legacy keys exist.
if unset_env_key "$OBS_DST" "MQTT_USERNAME"; then
    CHANGED=1
    LEGACY_SECRET_KEYS_REMOVED=$((LEGACY_SECRET_KEYS_REMOVED + 1))
fi
if unset_env_key "$OBS_DST" "MQTT_PASSWORD"; then
    CHANGED=1
    LEGACY_SECRET_KEYS_REMOVED=$((LEGACY_SECRET_KEYS_REMOVED + 1))
fi
if unset_env_key "$OBS_DST" "INFLUXDB_USERNAME"; then
    CHANGED=1
    LEGACY_SECRET_KEYS_REMOVED=$((LEGACY_SECRET_KEYS_REMOVED + 1))
fi
if unset_env_key "$OBS_DST" "INFLUXDB_PASSWORD"; then
    CHANGED=1
    LEGACY_SECRET_KEYS_REMOVED=$((LEGACY_SECRET_KEYS_REMOVED + 1))
fi

# Also seed profiles shipped in the image if missing (handles overlayfs on /etc)
if [ -d /usr/share/iotgw-nm/connections ]; then
    install -d /etc/NetworkManager/system-connections
    for f in /usr/share/iotgw-nm/connections/*.nmconnection; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        if [ ! -e "/etc/NetworkManager/system-connections/$bn" ]; then
            install -m 0600 "$f" /etc/NetworkManager/system-connections/
        fi
    done
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection reload || true
    fi
fi

# Only mark as provisioned if we actually changed something. This allows
# adding files to /data/iotgw later and having the service run again.
if [ "$CHANGED" -eq 1 ]; then
    touch "$STAMP"
fi
if [ "$CHANGED" -eq 1 ]; then
    log "✅ [provision] Completed: applied profiles and stamped"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart mosquitto.service telegraf.service || true
    fi
else
    log "✅ [provision] Completed: no changes"
fi
log "[provision] Summary: changed=${CHANGED} source=${OBS_SOURCE} nm_profiles=${NM_PROFILE_UPDATES} nm_conf=${NM_CONF_UPDATES} cred_updates=${OBS_CRED_UPDATES} broker_applied=${OBS_BROKER_APPLIED} legacy_keys_removed=${LEGACY_SECRET_KEYS_REMOVED} uboot_env_updates=${UBOOT_ENV_UPDATES} warnings=${WARNINGS}"
exit "$RC_OK"
