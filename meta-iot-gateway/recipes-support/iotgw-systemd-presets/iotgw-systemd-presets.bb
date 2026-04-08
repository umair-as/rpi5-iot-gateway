SUMMARY = "IoT GW systemd presets (enable baseline services)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-iotgw.preset"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${libdir}/systemd/system-preset
    install -m 0644 ${WORKDIR}/90-iotgw.preset ${D}${libdir}/systemd/system-preset/90-iotgw.preset
}

FILES:${PN} = "${libdir}/systemd/system-preset/90-iotgw.preset"

