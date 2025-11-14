SUMMARY = "IoT Gateway Dynamic Banner Generator"
DESCRIPTION = "Generates modern, colorful login banners with real-time system information"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-banner.sh \
    file://iotgw-banner.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-banner.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Install the banner generator script
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/iotgw-banner.sh ${D}${bindir}/iotgw-banner.sh

    # Substitute variables in the script using @ delimiters
    sed -i -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
           -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
           -e "s|@MACHINE@|${MACHINE}|g" \
           ${D}${bindir}/iotgw-banner.sh

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-banner.service ${D}${systemd_system_unitdir}/iotgw-banner.service
}

FILES:${PN} += " \
    ${bindir}/iotgw-banner.sh \
    ${systemd_system_unitdir}/iotgw-banner.service \
"

# Ensure this runs after base-files to override static issue/motd
RDEPENDS:${PN} = "bash iproute2"
