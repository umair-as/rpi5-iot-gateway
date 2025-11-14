SUMMARY = "Copy staged boot files into /boot at boot time"
DESCRIPTION = "Oneshot systemd service that copies /usr/share/iotgw/bootfiles/* into /boot, ensuring U-Boot boot.scr, u-boot.bin, and splash.bmp are updated without raw writes."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = "file://iotgw-update-bootfiles.sh file://iotgw-update-bootfiles.service"

S = "${WORKDIR}"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "iotgw-update-bootfiles.service"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/iotgw-update-bootfiles.sh ${D}${bindir}/iotgw-update-bootfiles.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-update-bootfiles.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${systemd_system_unitdir}/iotgw-update-bootfiles.service ${bindir}/iotgw-update-bootfiles.sh"

RDEPENDS:${PN} = "bash coreutils"

