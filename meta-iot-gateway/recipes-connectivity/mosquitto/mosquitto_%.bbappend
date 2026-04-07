FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://mosquitto.conf \
    file://20-security.conf \
    file://acl \
    file://passwd \
"

do_install:append() {
    install -d ${D}${sysconfdir}/mosquitto
    install -m 0644 ${WORKDIR}/mosquitto.conf ${D}${sysconfdir}/mosquitto/mosquitto.conf
    install -d ${D}${sysconfdir}/mosquitto/conf.d
    install -m 0644 ${WORKDIR}/20-security.conf ${D}${sysconfdir}/mosquitto/conf.d/20-security.conf
    # Baseline secure defaults in new rootfs content.
    # Provisioning/RAUC reconciliation enforce mosquitto:mosquitto ownership at runtime.
    install -m 0600 ${WORKDIR}/acl ${D}${sysconfdir}/mosquitto/acl
    install -m 0600 ${WORKDIR}/passwd ${D}${sysconfdir}/mosquitto/passwd
}
