SUMMARY = "Label the persistent /data partition with the SELinux file contexts"
DESCRIPTION = "The read-only root is labelled at build time; /data is not part of \
the image, so its inodes come up unlabeled_t. Relabels /data with restorecon \
whenever the policy or file contexts change, using the /data aliases shipped by \
the refpolicy-mcs bbappend. See docs/SELINUX.md."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://iotgw-selinux-relabel.sh \
    file://iotgw-selinux-relabel.service \
"

inherit systemd features_check

REQUIRED_DISTRO_FEATURES = "selinux systemd"

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "iotgw-selinux-relabel.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/iotgw-selinux-relabel.sh ${D}${sbindir}/iotgw-selinux-relabel

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-selinux-relabel.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    ${sbindir}/iotgw-selinux-relabel \
    ${systemd_system_unitdir}/iotgw-selinux-relabel.service \
"

RDEPENDS:${PN} = "policycoreutils-setfiles coreutils"
