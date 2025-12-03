SUMMARY = "IoT Gateway nftables baseline service"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://iotgw-nftables.service"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-nftables.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "nftables"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-nftables.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} = "${systemd_system_unitdir}/iotgw-nftables.service"

