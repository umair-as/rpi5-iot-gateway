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

# Configure NAT44 and forwarding via nftables (no legacy xtables modules)
echo "Configuring nftables NAT and forwarding for Thread ↔ Infrastructure..."

# Remove any previous otbr table to avoid duplicate rules
nft delete table inet otbr >/dev/null 2>&1 || true

nft -f - <<EOF
table inet otbr {
    chain mangle_prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname "$THREAD_IF" meta mark set 0x1001
    }

    chain filter_forward {
        type filter hook forward priority filter; policy accept;
        oifname "$INFRA_IF" accept
        iifname "$INFRA_IF" accept
    }

    chain nat_postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        meta mark 0x1001 masquerade
    }
}
EOF

echo "OTBR nftables initialization complete"
exit 0
