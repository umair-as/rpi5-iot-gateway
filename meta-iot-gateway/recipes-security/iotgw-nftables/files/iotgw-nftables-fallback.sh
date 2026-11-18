#!/bin/sh
# ExecStopPost= helper of iotgw-nftables.service.
#
# systemd runs ExecStopPost= after every stop of the unit, including the stop
# that follows a failed ExecStartPre=/ExecStart=, and exports the outcome as
# SERVICE_RESULT. A clean stop ("success": systemctl stop, shutdown) leaves
# the loaded ruleset alone. Any other result means /etc/nftables.conf did not
# make it into the kernel, and the kernel is then running its default
# accept-everything policy on the input and forward hooks. This installs the
# minimal known-good ruleset instead: loopback, established flows, ICMP for
# path and neighbour discovery, and SSH on IPv4 - the baseline input policy
# without any optional service admission, and no forwarding at all.
#
# The fallback ruleset is inline rather than a second file so that it cannot
# be absent or diverge from the unit that depends on it. It names the same
# table as the baseline so that a later successful (re)load replaces it.

[ "${SERVICE_RESULT:-}" = "success" ] && exit 0

echo "iotgw-nftables: ruleset load failed (${SERVICE_RESULT:-unknown}); installing the fail-closed fallback" >&2

# One transaction, as in /etc/nftables.conf: whatever is left of the table is
# replaced together with the new definition, or not at all.
nft -f - <<'EOF'
table inet filter
delete table inet filter
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    meta nfproto ipv4 tcp dport 22 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid { @IOTGW_CTR_UID@, @IOTGW_CTR_SUBID_RANGE@ } oifname "lo" ct state new drop
    meta skuid { @IOTGW_CTR_UID@, @IOTGW_CTR_SUBID_RANGE@ } ip daddr { 224.0.0.0/4, 255.255.255.255 } drop
    meta skuid { @IOTGW_CTR_UID@, @IOTGW_CTR_SUBID_RANGE@ } ip6 daddr ff00::/8 drop
  }
}
EOF
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "iotgw-nftables: fallback ruleset failed too (nft exit $rc); the kernel default policy is in force" >&2
fi
exit "$rc"
