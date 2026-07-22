SUMMARY = "Overlayfs setup for read-only rootfs with RAUC"
DESCRIPTION = "Provides overlayfs mounts for writable directories (/etc, /home, /root) on top of read-only rootfs"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://overlayfs-setup.sh \
    file://overlayfs-setup.service \
    file://iotgw-var-volatile-relabel.tmpfiles.conf \
    file://systemd-timesyncd-after-volatile-lib.conf \
"

inherit systemd

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "overlayfs-setup.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Install the setup script
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/overlayfs-setup.sh ${D}${sbindir}/overlayfs-setup.sh

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/overlayfs-setup.service ${D}${systemd_system_unitdir}/

    # Relabel the volatile /var/volatile tmpfs root after policy load.
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iotgw-var-volatile-relabel.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/iotgw-var-volatile-relabel.conf

    # Order timesyncd after the volatile-binds /var/lib so its StateDirectory
    # can be created (no more early 238/STATE_DIRECTORY failures).
    install -d ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d
    install -m 0644 ${UNPACKDIR}/systemd-timesyncd-after-volatile-lib.conf \
        ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d/10-iotgw-after-volatile-lib.conf
}

FILES:${PN} += " \
    ${sbindir}/overlayfs-setup.sh \
    ${systemd_system_unitdir}/overlayfs-setup.service \
    ${sysconfdir}/tmpfiles.d/iotgw-var-volatile-relabel.conf \
    ${systemd_system_unitdir}/systemd-timesyncd.service.d/10-iotgw-after-volatile-lib.conf \
"
RDEPENDS:${PN} += "bash"
