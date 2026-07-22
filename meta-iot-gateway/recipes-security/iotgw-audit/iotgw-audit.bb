SUMMARY = "IoT Gateway Audit Configuration"
DESCRIPTION = "Audit daemon configuration for security monitoring"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://audit.rules file://auditd.conf"

# Ensure auditd is present and owns /etc/audit; avoid packaging that directory here
RDEPENDS:${PN} = "auditd"

S = "${UNPACKDIR}"

do_install() {
    # Stage under datadir — auditd owns /etc/audit and /etc/audit/rules.d, so we
    # cannot package into those directories directly. iotgw-rootfs.bbclass deploys
    # the rules and auditd.conf into the image rootfs via ROOTFS_POSTPROCESS_COMMAND.
    install -d ${D}${datadir}/iotgw-audit
    install -m 0640 ${UNPACKDIR}/audit.rules ${D}${datadir}/iotgw-audit/iotgw.rules
    install -m 0640 ${UNPACKDIR}/auditd.conf ${D}${datadir}/iotgw-audit/auditd.conf
}

FILES:${PN} = "${datadir}/iotgw-audit/iotgw.rules ${datadir}/iotgw-audit/auditd.conf"
