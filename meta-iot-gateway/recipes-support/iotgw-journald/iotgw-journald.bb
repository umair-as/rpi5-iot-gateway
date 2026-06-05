SUMMARY = "IoT GW journald retention and size limits"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://iotgw.conf file://iotgw-journald.tmpfiles"

S = "${WORKDIR}"

# Recipe ships only static config (journald.conf.d drop-in + tmpfiles.d
# entry). No machine- or tune-specific expansions, so allarch is correct
# and avoids per-tune rebuilds.
inherit allarch

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
