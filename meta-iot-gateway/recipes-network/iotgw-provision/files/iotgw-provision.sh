#!/bin/bash
set -euo pipefail

STAMP="/var/lib/iotgw-provision.done"
SRC_DIR="/boot/iotgw"

mkdir -p /var/lib

if [ -e "$STAMP" ]; then
    exit 0
fi

# SSH authorized_keys
if [ -f "$SRC_DIR/authorized_keys" ]; then
    install -d -m 0700 /root/.ssh
    install -m 0600 "$SRC_DIR/authorized_keys" /root/.ssh/authorized_keys
fi

# NetworkManager profiles and conf.d
if [ -d "$SRC_DIR/nm" ]; then
    install -d /etc/NetworkManager/system-connections
    for f in "$SRC_DIR"/nm/*.nmconnection; do
        [ -e "$f" ] || continue
        install -m 0600 "$f" /etc/NetworkManager/system-connections/
    done
    # Optional: backend/config overrides
    if [ -d "$SRC_DIR/nm-conf" ]; then
        install -d /etc/NetworkManager/conf.d
        for c in "$SRC_DIR"/nm-conf/*.conf; do
            [ -e "$c" ] || continue
            install -m 0644 "$c" /etc/NetworkManager/conf.d/
        done
    fi
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection reload || true
    fi
fi

touch "$STAMP"
exit 0
