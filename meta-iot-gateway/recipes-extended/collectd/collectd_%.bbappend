#
# IoT Gateway collectd defaults:
# - Disable upstream multicast forwarding endpoints by default.
# - Allow explicit unicast forwarding via build-time variables.
#
# Set in kas/local.yml (local_conf_header) when needed:
#   IOTGW_COLLECTD_SERVER = "192.168.0.230"
#   IOTGW_COLLECTD_PORT = "25826"
#

IOTGW_COLLECTD_SERVER ?= ""
IOTGW_COLLECTD_PORT ?= "25826"

do_install:append() {
    conf="${D}${sysconfdir}/collectd.conf"

    # Stop default multicast forwarding from upstream sample config.
    sed -i 's/^[[:space:]]*Server "ff18::efc0:4a42" "25826"/# Server "ff18::efc0:4a42" "25826"  # disabled by iotgw/' "$conf"
    sed -i '/^[[:space:]]*<Server "239.192.74.66" "25826">/,/^[[:space:]]*<\/Server>/ s/^[[:space:]]*/# &/' "$conf"

    # Add explicit unicast receiver endpoint if configured.
    if [ -n "${IOTGW_COLLECTD_SERVER}" ]; then
        if ! grep -q "Server \"${IOTGW_COLLECTD_SERVER}\" \"${IOTGW_COLLECTD_PORT}\"" "$conf"; then
            sed -i "/^[[:space:]]*<Plugin network>/a\\        Server \"${IOTGW_COLLECTD_SERVER}\" \"${IOTGW_COLLECTD_PORT}\"" "$conf"
        fi
    fi
}
