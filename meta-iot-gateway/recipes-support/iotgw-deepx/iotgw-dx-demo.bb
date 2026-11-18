SUMMARY = "DX-M1 desktop demo launcher"
DESCRIPTION = "Starts the vendor DX-Stream sample pipeline on the Weston display \
as a dedicated unprivileged account, and relaunches it at end of stream."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The demo unit only. The launcher binary, its account and the inference probe
# are iotgw-dx-demo-probe, which every DX-M1 image takes; this recipe adds the
# sample pipeline and its Weston dependency (desktop only). The wayland
# supplementary group of the account is declared by the desktop image.
SRC_URI = "file://iotgw-dx-demo.service"

S = "${UNPACKDIR}"

inherit systemd

# Installed, not enabled: the image does not autoplay the demo at boot.
# Start it with `systemctl start iotgw-dx-demo` (the acceptance run does).
SYSTEMD_SERVICE:${PN} = "iotgw-dx-demo.service"
SYSTEMD_AUTO_ENABLE = "disable"

RDEPENDS:${PN} = "iotgw-dx-demo-probe dx-stream-sample weston-init"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-dx-demo.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} = "${systemd_system_unitdir}/iotgw-dx-demo.service"

COMPATIBLE_MACHINE = "raspberrypi5"
