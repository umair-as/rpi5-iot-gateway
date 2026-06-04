# Maintained asset: not included in any image variant by default.
# Kept current for layer consumers deploying InfluxDB 1.x on Scarthgap.
# To reinstate, add influxdb to IMAGE_INSTALL in a downstream image variant.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://influxdb.service.d-10-iotgw-hardening.conf \
"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}/influxdb.service.d
    install -m 0644 ${WORKDIR}/influxdb.service.d-10-iotgw-hardening.conf \
        ${D}${systemd_system_unitdir}/influxdb.service.d/10-iotgw-hardening.conf
}

FILES:${PN}:append = " \
    ${systemd_system_unitdir}/influxdb.service.d/10-iotgw-hardening.conf \
"
