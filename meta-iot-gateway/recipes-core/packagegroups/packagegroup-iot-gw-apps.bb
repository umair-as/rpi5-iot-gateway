SUMMARY = "IoT GW Applications package group"
DESCRIPTION = "IoT gateway services: MQTT, protocols, DB, monitoring, Node.js"
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch so we can depend on dynamically renamed libs (ABI/versioned)
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Optional application feature toggles
IOTGW_ENABLE_EDGE_HEALTHD ?= "0"

PACKAGES = " \
    ${PN} \
    ${PN}-mqtt \
    ${PN}-protocols \
    ${PN}-database \
    ${PN}-monitoring \
    ${PN}-node-runtime \
"

RDEPENDS:${PN} = " \
    ${PN}-mqtt \
    ${PN}-protocols \
    ${PN}-database \
    ${PN}-monitoring \
"

# Optional slices (enable per-image as needed)
# - ${PN}-node-runtime: Node.js runtime for on-host apps
# - grafana/influxdb: add via RRECOMMENDS or image-specific install when recipes are available

RDEPENDS:${PN}-mqtt = " \
    mosquitto \
    mosquitto-clients \
"

RDEPENDS:${PN}-protocols = " \
    curl \
    wget \
    nmap \
"

RDEPENDS:${PN}-database = " \
    sqlite3 \
"

RDEPENDS:${PN}-monitoring = " \
    sysstat \
"
RDEPENDS:${PN}-monitoring:append = "${@bb.utils.contains('IOTGW_ENABLE_EDGE_HEALTHD','1',' edge-healthd','',d)}"

RDEPENDS:${PN}-node-runtime = " \
    nodejs \
    nodejs-npm \
"
