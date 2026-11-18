SUMMARY = "IoT Gateway OpenSSH server policy: key-only defaults for every tier, plus the prod override package"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-iotgw.conf file://10-iotgw-prod-auth.conf"

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} += "openssh-sshd"

# ${PN}-prod: installed by packagegroup-iot-gw-prod only. sshd takes the FIRST
# value it sees for a keyword, and sshd_config.d/*.conf is included in lexical
# order, so 10-iotgw-prod-auth.conf wins over 99-iotgw.conf without forking the
# shared file. The prod hygiene gate (iotgw-rootfs.bbclass) requires it.
PACKAGES =+ "${PN}-prod"

do_install() {
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/99-iotgw.conf ${D}${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf
    install -m 0644 ${UNPACKDIR}/10-iotgw-prod-auth.conf ${D}${sysconfdir}/ssh/sshd_config.d/10-iotgw-prod-auth.conf
}

# No pkg_postinst: the image set does not ship run-postinsts.service, so
# the `if [ -z "$D" ]; then … fi` body would never fire on target. The
# Include /etc/ssh/sshd_config.d/*.conf line is already present in the
# stock openssh sshd_config shipped by poky, so the previous postinst was
# a no-op on top of being unreachable.

FILES:${PN} = "${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf"
FILES:${PN}-prod = "${sysconfdir}/ssh/sshd_config.d/10-iotgw-prod-auth.conf"
RDEPENDS:${PN}-prod += "${PN}"

