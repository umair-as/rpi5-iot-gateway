SUMMARY = "Persistent machine-id setup for immutable rootfs deployments"
DESCRIPTION = "Ensures machine-id is persisted under /data and bind-mounted to /etc/machine-id before regular services."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://iotgw-machine-id.sh \
    file://iotgw-machine-id.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-machine-id.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-machine-id.sh ${D}${sbindir}/iotgw-machine-id

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-machine-id.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${sbindir}/iotgw-machine-id \
    ${systemd_system_unitdir}/iotgw-machine-id.service \
"

RDEPENDS:${PN} += "bash util-linux systemd"
