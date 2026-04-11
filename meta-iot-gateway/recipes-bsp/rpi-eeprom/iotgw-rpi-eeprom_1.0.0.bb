SUMMARY = "IoT Gateway policy wrapper for Raspberry Pi EEPROM updates"
DESCRIPTION = "Installs a controlled wrapper and optional systemd policy service for rpi-eeprom-update."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://iotgw-rpi-eeprom \
    file://iotgw-rpi-eeprom.service \
    file://iotgw-rpi-eeprom.default \
"

S = "${WORKDIR}"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "iotgw-rpi-eeprom.service"
SYSTEMD_AUTO_ENABLE = "disable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-rpi-eeprom ${D}${sbindir}/iotgw-rpi-eeprom

    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/iotgw-rpi-eeprom.default ${D}${sysconfdir}/default/iotgw-rpi-eeprom

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-rpi-eeprom.service ${D}${systemd_system_unitdir}/iotgw-rpi-eeprom.service
}

FILES:${PN} += " \
    ${sbindir}/iotgw-rpi-eeprom \
    ${sysconfdir}/default/iotgw-rpi-eeprom \
    ${systemd_system_unitdir}/iotgw-rpi-eeprom.service \
"

RDEPENDS:${PN} = " \
    rpi-eeprom \
    raspi-utils \
    coreutils \
"
