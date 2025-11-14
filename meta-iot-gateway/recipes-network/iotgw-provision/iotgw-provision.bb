SUMMARY = "IoT GW first-boot provisioning (keys, NM profiles)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-provision.sh \
    file://iotgw-provision.service \
"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-provision.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/iotgw-provision.sh ${D}${bindir}/iotgw-provision.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-provision.service ${D}${systemd_system_unitdir}/iotgw-provision.service
}

FILES:${PN} += " \
    ${bindir}/iotgw-provision.sh \
    ${systemd_system_unitdir}/iotgw-provision.service \
"

RDEPENDS:${PN} = "bash networkmanager"

