#!/bin/bash
set -euo pipefail

STAMP="/var/lib/iotgw-provision.done"
SRC_DIR="/boot/iotgw"
CHANGED=0

mkdir -p /var/lib

log() { echo "$*" >&2; }
log "📦 [provision] Start: NetworkManager profiles (first-boot)"

# Sanity: check /boot mount (unit RequiresMountsFor=/boot should ensure this)
if mountpoint -q /boot; then
    log "🔍 [provision] /boot is mounted"
else
    log "⚠️  [provision] /boot not mounted; continuing (no profiles will be found)"
fi

# Exit early if already provisioned
if [ -e "$STAMP" ]; then
    log "✅ [provision] Already provisioned; nothing to do"
    exit 0
fi

# Ensure provisioning directory exists on the boot partition for convenience
mkdir -p "$SRC_DIR" || true

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
# adding files to /boot/iotgw later and having the service run again.
if [ "$CHANGED" -eq 1 ]; then
    touch "$STAMP"
fi
if [ "$CHANGED" -eq 1 ]; then
    log "✅ [provision] Completed: applied profiles and stamped"
else
    log "✅ [provision] Completed: no changes"
fi
exit 0
