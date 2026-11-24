# The package stays installed: podman RDEPENDS on it. Its boot units do not
# run: they restore rules with iptables-legacy (xtables-legacy-multi), and this
# distro's kernel has no legacy x_tables engine. All firewalling is nftables
# (iotgw-firewall, netavark with firewall_driver = "nftables").
SYSTEMD_AUTO_ENABLE:${PN} = "disable"
