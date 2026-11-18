# Scope mDNS to the infrastructure interface. avahi binds the wildcard address
# on every interface and parses mDNS from the link before any authentication;
# on this gateway it exists for OTBR's advertising proxy and for operator
# discovery (<hostname>.local), both on the infrastructure link only. The
# firewall admits 5353 on that interface alone (iotgw-firewall, OTBR builds);
# this keeps the daemon's own view consistent with the firewall's.
IOTGW_OTBR_INFRA_IFACE ?= "wlan0"

do_install:append() {
    conf=${D}${sysconfdir}/avahi/avahi-daemon.conf
    if [ -f "$conf" ]; then
        sed -i -e 's/^#\?allow-interfaces=.*/allow-interfaces=${IOTGW_OTBR_INFRA_IFACE}/' \
               -e 's/^#\?publish-workstation=.*/publish-workstation=no/' "$conf"
        grep -q '^allow-interfaces=${IOTGW_OTBR_INFRA_IFACE}$' "$conf" || \
            bbfatal "avahi: allow-interfaces not set in avahi-daemon.conf"
    fi
}
