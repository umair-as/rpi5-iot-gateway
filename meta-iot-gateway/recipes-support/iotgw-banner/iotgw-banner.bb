SUMMARY = "IoT Gateway login banners"
DESCRIPTION = "Ships static pre-login console/SSH banners and a small \
profile.d appendix that prints live system state for interactive shells. \
Console IP addresses use agetty issue escapes, so no dispatcher daemon or \
refresh service is required."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://issue.in \
    file://issue.net.in \
    file://motd.in \
    file://iotgw-motd-dynamic.sh \
"

S = "${UNPACKDIR}"

do_install() {
    esc="$(printf '\033')"

    install -d ${D}${sysconfdir}
    for banner in issue issue.net motd; do
        sed -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
            -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
            -e "s|@MACHINE@|${MACHINE}|g" \
            -e "s|@ESC@|${esc}|g" \
            ${UNPACKDIR}/${banner}.in > ${D}${sysconfdir}/${banner}
        chmod 0644 ${D}${sysconfdir}/${banner}
    done

    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/iotgw-motd-dynamic.sh \
        ${D}${sysconfdir}/profile.d/iotgw-motd-dynamic.sh
}

FILES:${PN} += " \
    ${sysconfdir}/issue \
    ${sysconfdir}/issue.net \
    ${sysconfdir}/motd \
    ${sysconfdir}/profile.d/iotgw-motd-dynamic.sh \
"

# iproute2 is used by the live interactive-shell appendix to report the
# default-route source address.
RDEPENDS:${PN} = "iproute2"
