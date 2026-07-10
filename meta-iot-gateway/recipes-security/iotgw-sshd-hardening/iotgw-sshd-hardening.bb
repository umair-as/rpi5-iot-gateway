SUMMARY = "IoT Gateway OpenSSH server hardening (dev-friendly)"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-iotgw.conf"

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} += "openssh-sshd"

do_install() {
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/99-iotgw.conf ${D}${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf
}

# No pkg_postinst: the image set does not ship run-postinsts.service, so
# the `if [ -z "$D" ]; then … fi` body would never fire on target. The
# Include /etc/ssh/sshd_config.d/*.conf line is already present in the
# stock openssh sshd_config shipped by poky, so the previous postinst was
# a no-op on top of being unreachable.

FILES:${PN} = "${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf"

