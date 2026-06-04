SUMMARY = "Crash-debug sysctl defaults for lab builds"
DESCRIPTION = "Installs sysctl defaults for panic reboot and sysrq to support repeatable crash validation workflows."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://95-iotgw-crash-debug.conf"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${datadir}/iotgw-sysctl
    install -m 0644 ${WORKDIR}/95-iotgw-crash-debug.conf \
        ${D}${datadir}/iotgw-sysctl/95-iotgw-crash-debug.conf
}

FILES:${PN} = "${datadir}/iotgw-sysctl/95-iotgw-crash-debug.conf"
