SUMMARY = "Overlayfs setup for read-only rootfs with RAUC"
DESCRIPTION = "Provides overlayfs mounts for writable directories (/etc, /var, /home, /root) on top of read-only rootfs"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://overlayfs-setup.sh \
    file://overlayfs-setup.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "overlayfs-setup.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Install the setup script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/overlayfs-setup.sh ${D}${sbindir}/overlayfs-setup.sh

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/overlayfs-setup.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${sbindir}/overlayfs-setup.sh \
    ${systemd_system_unitdir}/overlayfs-setup.service \
"
RDEPENDS:${PN} += "bash"
