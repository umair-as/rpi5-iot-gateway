SUMMARY = "IoT Gateway U-Boot bootstage collector"
DESCRIPTION = "Collects U-Boot bootstage timings from device tree in userspace and publishes them to journald."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-bootstage.sh \
    file://iotgw-bootstage.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-bootstage.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "bash"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/iotgw-bootstage.sh ${D}${bindir}/iotgw-bootstage

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-bootstage.service ${D}${systemd_system_unitdir}/iotgw-bootstage.service
}

FILES:${PN} += " \
    ${bindir}/iotgw-bootstage \
    ${systemd_system_unitdir}/iotgw-bootstage.service \
"
