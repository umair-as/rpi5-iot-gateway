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
    install -m 0644 ${WORKDIR}/acl ${D}${sysconfdir}/mosquitto/acl
    install -m 0644 ${WORKDIR}/passwd ${D}${sysconfdir}/mosquitto/passwd
}
