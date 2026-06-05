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
