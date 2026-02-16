SUMMARY = "IoT GW journald retention and size limits"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://iotgw.conf file://iotgw-journald.tmpfiles"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/iotgw-journald
    install -m 0644 ${WORKDIR}/iotgw.conf ${D}${datadir}/iotgw-journald/iotgw.conf

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/iotgw-journald.tmpfiles \
        ${D}${sysconfdir}/tmpfiles.d/iotgw-journald.conf
}

FILES:${PN} = " \
    ${datadir}/iotgw-journald/iotgw.conf \
    ${sysconfdir}/tmpfiles.d/iotgw-journald.conf \
"
