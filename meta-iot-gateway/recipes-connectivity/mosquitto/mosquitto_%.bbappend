FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://mosquitto.conf \
    file://20-security.conf \
    file://acl \
    file://passwd \
    file://iotgw-mosquitto-persist.tmpfiles.conf \
"

do_install:append() {
    install -d ${D}${sysconfdir}/mosquitto
    install -m 0644 ${UNPACKDIR}/mosquitto.conf ${D}${sysconfdir}/mosquitto/mosquitto.conf
    install -d ${D}${sysconfdir}/mosquitto/conf.d
    install -m 0644 ${UNPACKDIR}/20-security.conf ${D}${sysconfdir}/mosquitto/conf.d/20-security.conf
    # Baseline secure defaults in new rootfs content.
    # Provisioning/RAUC reconciliation enforce mosquitto:mosquitto ownership at runtime.
    install -m 0600 ${UNPACKDIR}/acl ${D}${sysconfdir}/mosquitto/acl
    install -m 0600 ${UNPACKDIR}/passwd ${D}${sysconfdir}/mosquitto/passwd

    # Create the persistent /data-backed state dir (persistence_location).
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iotgw-mosquitto-persist.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/iotgw-mosquitto-persist.conf
}

FILES:${PN} += "${sysconfdir}/tmpfiles.d/iotgw-mosquitto-persist.conf"
