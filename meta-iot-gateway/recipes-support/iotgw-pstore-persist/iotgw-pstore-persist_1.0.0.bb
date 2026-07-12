SUMMARY = "Persist systemd-pstore archives on /data for read-only rootfs deployments"
DESCRIPTION = "Bind-mounts /data/crash/pstore onto /var/lib/systemd/pstore via a systemd .mount unit so kernel pstore records survive reboot, and prunes stale records by count and size."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://var-lib-systemd-pstore.mount \
    file://iotgw-pstore.tmpfiles.conf \
    file://iotgw-pstore-prune.sh \
    file://iotgw-pstore-prune.service \
    file://10-iotgw-pstore-persist.conf \
"

inherit systemd

# var-lib-systemd-pstore.mount is pulled in on demand by systemd-pstore.service
# via the RequiresMountsFor= drop-in, so it does not need [Install] / preset.
SYSTEMD_SERVICE:${PN} = "iotgw-pstore-prune.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/iotgw-pstore-prune.sh ${D}${sbindir}/iotgw-pstore-prune

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/var-lib-systemd-pstore.mount ${D}${systemd_system_unitdir}/var-lib-systemd-pstore.mount
    install -m 0644 ${UNPACKDIR}/iotgw-pstore-prune.service ${D}${systemd_system_unitdir}/iotgw-pstore-prune.service

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iotgw-pstore.tmpfiles.conf ${D}${sysconfdir}/tmpfiles.d/iotgw-pstore.conf

    install -d ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-pstore-persist.conf \
        ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d/10-iotgw-pstore-persist.conf
}

FILES:${PN} += " \
    ${sbindir}/iotgw-pstore-prune \
    ${systemd_system_unitdir}/var-lib-systemd-pstore.mount \
    ${systemd_system_unitdir}/iotgw-pstore-prune.service \
    ${sysconfdir}/tmpfiles.d/iotgw-pstore.conf \
    ${sysconfdir}/systemd/system/systemd-pstore.service.d/10-iotgw-pstore-persist.conf \
"

RDEPENDS:${PN} += "bash util-linux systemd xz"
