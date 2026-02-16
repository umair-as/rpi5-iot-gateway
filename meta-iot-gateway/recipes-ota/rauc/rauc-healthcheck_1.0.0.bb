SUMMARY = "RAUC health check marker"
DESCRIPTION = "Marks the booted RAUC slot good after basic system readiness"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://rauc-healthcheck.sh file://rauc-healthcheck.service"

S = "${WORKDIR}"

SYSTEMD_SERVICE:${PN} = "rauc-healthcheck.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "rauc jq bash"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/rauc-healthcheck.sh ${D}${sbindir}/rauc-healthcheck

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rauc-healthcheck.service \
        ${D}${systemd_system_unitdir}/rauc-healthcheck.service
}

FILES:${PN} += "${sbindir}/rauc-healthcheck ${systemd_system_unitdir}/rauc-healthcheck.service"
