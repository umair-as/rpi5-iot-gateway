SUMMARY = "RAUC boot backup prune helper"
DESCRIPTION = "Prunes old /boot backup artifacts after RAUC mark-good flow"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://boot-backup-prune.sh \
    file://boot-backup-prune.service \
"

S = "${WORKDIR}"

SYSTEMD_SERVICE:${PN} = "boot-backup-prune.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "bash"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/boot-backup-prune.sh ${D}${sbindir}/boot-backup-prune

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/boot-backup-prune.service \
        ${D}${systemd_system_unitdir}/boot-backup-prune.service
}

FILES:${PN} += " \
    ${sbindir}/boot-backup-prune \
    ${systemd_system_unitdir}/boot-backup-prune.service \
"
