SUMMARY = "Sudoers configuration for IoT Gateway devel user"
DESCRIPTION = "Provides passwordless sudo access for devel user to run admin and security tools"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://devel"

S = "${WORKDIR}"

# Depend on sudo to ensure /etc/sudoers.d exists
RDEPENDS:${PN} = "sudo"

do_install() {
    # Stage the sudoers snippet in datadir; final placement handled by ROOTFS_POSTPROCESS_COMMAND
    install -d ${D}${datadir}/${PN}
    install -m 0440 ${WORKDIR}/devel ${D}${datadir}/${PN}/devel
}

FILES:${PN} = "${datadir}/${PN}/devel"
