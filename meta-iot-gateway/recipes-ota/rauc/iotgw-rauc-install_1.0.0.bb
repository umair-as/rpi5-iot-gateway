SUMMARY = "Safe RAUC install wrapper for read-only /boot setups"
DESCRIPTION = "Runs rauc install and remounts /boot rw only when fw_env.config targets /boot; otherwise installs directly."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-rauc-install.sh \
"

S = "${WORKDIR}"

RDEPENDS:${PN} = "bash curl rauc systemd util-linux"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-rauc-install.sh ${D}${sbindir}/iotgw-rauc-install
}

FILES:${PN} += " ${sbindir}/iotgw-rauc-install "
