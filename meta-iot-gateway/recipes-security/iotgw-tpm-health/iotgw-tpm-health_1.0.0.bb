SUMMARY = "IoT GW TPM runtime health probe"
DESCRIPTION = "Runs a non-blocking TPM health baseline at boot and writes evidence artifacts under /data/ota/tpm."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-tpm-health.sh \
    file://iotgw-tpm-health.service \
    file://iotgw-tpm-health.tmpfiles.conf \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-tpm-health.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-tpm-health.sh ${D}${sbindir}/iotgw-tpm-health

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-tpm-health.service ${D}${systemd_system_unitdir}/

    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/iotgw-tpm-health.tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/iotgw-tpm-health.conf
}

FILES:${PN} += " \
    ${sbindir}/iotgw-tpm-health \
    ${systemd_system_unitdir}/iotgw-tpm-health.service \
    ${nonarch_libdir}/tmpfiles.d/iotgw-tpm-health.conf \
"

RDEPENDS:${PN} += "bash tpm-ops"
