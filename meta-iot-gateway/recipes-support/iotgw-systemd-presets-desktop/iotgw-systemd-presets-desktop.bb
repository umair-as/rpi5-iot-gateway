SUMMARY = "IoT GW systemd presets for desktop image variant (Weston)"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://91-iotgw-desktop.preset"

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${libdir}/systemd/system-preset
    install -m 0644 ${UNPACKDIR}/91-iotgw-desktop.preset \
        ${D}${libdir}/systemd/system-preset/91-iotgw-desktop.preset
}

FILES:${PN} = "${libdir}/systemd/system-preset/91-iotgw-desktop.preset"
