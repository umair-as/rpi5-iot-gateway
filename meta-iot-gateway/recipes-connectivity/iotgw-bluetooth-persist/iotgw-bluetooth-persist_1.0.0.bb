SUMMARY = "Persist Bluetooth adapter identity and pairings on /data"
DESCRIPTION = "Bind-mounts /data/lib/bluetooth onto /var/lib/bluetooth so BlueZ adapter identity and \
device pairings survive reboot once /var is no longer overlaid (volatile /var/lib)."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://var-lib-bluetooth.mount \
    file://10-iotgw-bluetooth-persist.conf \
    file://iotgw-bluetooth-persist.tmpfiles.conf \
"

S = "${UNPACKDIR}"

# The .mount carries no [Install]; it is pulled on demand by the RequiresMountsFor
# drop-in on bluetooth.service.
do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-bluetooth.mount ${D}${systemd_system_unitdir}/var-lib-bluetooth.mount

    install -d ${D}${systemd_system_unitdir}/bluetooth.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-bluetooth-persist.conf \
        ${D}${systemd_system_unitdir}/bluetooth.service.d/10-iotgw-bluetooth-persist.conf

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iotgw-bluetooth-persist.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/iotgw-bluetooth-persist.conf
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/var-lib-bluetooth.mount \
    ${systemd_system_unitdir}/bluetooth.service.d/10-iotgw-bluetooth-persist.conf \
    ${sysconfdir}/tmpfiles.d/iotgw-bluetooth-persist.conf \
"

RDEPENDS:${PN} += "util-linux systemd"
