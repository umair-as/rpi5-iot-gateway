FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://containers.conf \
    file://storage.conf \
    file://90-iotgw-containers.conf \
    file://iotgw-containers.tmpfiles \
"

do_install:append() {
    install -d ${D}${sysconfdir}/containers
    install -m 0644 ${WORKDIR}/containers.conf ${D}${sysconfdir}/containers/containers.conf
    install -m 0644 ${WORKDIR}/storage.conf ${D}${sysconfdir}/containers/storage.conf

    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${WORKDIR}/90-iotgw-containers.conf ${D}${sysconfdir}/sysctl.d/90-iotgw-containers.conf

    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/iotgw-containers.tmpfiles ${D}${nonarch_libdir}/tmpfiles.d/iotgw-containers.conf
}

FILES:${PN}:append = " \
    ${sysconfdir}/containers/containers.conf \
    ${sysconfdir}/containers/storage.conf \
    ${sysconfdir}/sysctl.d/90-iotgw-containers.conf \
    ${nonarch_libdir}/tmpfiles.d/iotgw-containers.conf \
"

CONFFILES:${PN}:append = " \
    ${sysconfdir}/containers/containers.conf \
    ${sysconfdir}/containers/storage.conf \
    ${sysconfdir}/sysctl.d/90-iotgw-containers.conf \
"
