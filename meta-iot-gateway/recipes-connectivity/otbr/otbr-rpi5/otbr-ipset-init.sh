#!/bin/sh
# OTBR Firewall Initialization
# Based on OpenThread Border Router upstream scripts
set -e

THREAD_IF="${THREAD_IF:-wpan0}"
INFRA_IF="${INFRA_IF:-wlan0}"

# Create ipset sets expected by otbr-agent firewall logic (IPv6 sets)
# Using -exist so repeated runs are harmless
echo "Creating ipset sets for OTBR firewall..."
ipset create -exist otbr-ingress-deny-src hash:net family inet6 || true
ipset create -exist otbr-ingress-deny-src-swap hash:net family inet6 || true
ipset create -exist otbr-ingress-allow-dst hash:net family inet6 || true
ipset create -exist otbr-ingress-allow-dst-swap hash:net family inet6 || true

# Configure NAT44 for Thread network to infrastructure network routing
# This allows Thread devices to access the internet via the border router
echo "Configuring iptables NAT for Thread ↔ Infrastructure routing..."

# Mark Thread traffic for NAT
iptables -t mangle -C PREROUTING -i "$THREAD_IF" -j MARK --set-mark 0x1001 2>/dev/null || \
    iptables -t mangle -A PREROUTING -i "$THREAD_IF" -j MARK --set-mark 0x1001

# Masquerade marked traffic
iptables -t nat -C POSTROUTING -m mark --mark 0x1001 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -m mark --mark 0x1001 -j MASQUERADE

# Allow forwarding between Thread and infrastructure interfaces
iptables -t filter -C FORWARD -o "$INFRA_IF" -j ACCEPT 2>/dev/null || \
    iptables -t filter -A FORWARD -o "$INFRA_IF" -j ACCEPT

iptables -t filter -C FORWARD -i "$INFRA_IF" -j ACCEPT 2>/dev/null || \
    iptables -t filter -A FORWARD -i "$INFRA_IF" -j ACCEPT

echo "OTBR firewall initialization complete"
exit 0

