SUMMARY = "Persist systemd-pstore archives on /data for read-only rootfs deployments"
DESCRIPTION = "Prepares /data-backed storage and bind-mounts it onto /var/lib/systemd/pstore before systemd-pstore runs."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-pstore-persist.sh \
    file://iotgw-pstore-persist.service \
    file://iotgw-pstore-prune.sh \
    file://iotgw-pstore-prune.service \
    file://10-iotgw-pstore-persist.conf \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-pstore-persist.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-pstore-persist.sh ${D}${sbindir}/iotgw-pstore-persist
    install -m 0755 ${WORKDIR}/iotgw-pstore-prune.sh ${D}${sbindir}/iotgw-pstore-prune

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-pstore-persist.service ${D}${systemd_system_unitdir}/iotgw-pstore-persist.service
    install -m 0644 ${WORKDIR}/iotgw-pstore-prune.service ${D}${systemd_system_unitdir}/iotgw-pstore-prune.service

    install -d ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d
    install -m 0644 ${WORKDIR}/10-iotgw-pstore-persist.conf \
        ${D}${sysconfdir}/systemd/system/systemd-pstore.service.d/10-iotgw-pstore-persist.conf
}

FILES:${PN} += " \
    ${sbindir}/iotgw-pstore-persist \
    ${sbindir}/iotgw-pstore-prune \
    ${systemd_system_unitdir}/iotgw-pstore-persist.service \
    ${systemd_system_unitdir}/iotgw-pstore-prune.service \
    ${sysconfdir}/systemd/system/systemd-pstore.service.d/10-iotgw-pstore-persist.conf \
"

RDEPENDS:${PN} += "bash util-linux systemd"
