SUMMARY = "IoT Gateway Audit Configuration"
DESCRIPTION = "Audit daemon configuration for security monitoring"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://audit.rules"

# Ensure auditd is present and owns /etc/audit; avoid packaging that directory here
RDEPENDS:${PN} = "auditd"

S = "${WORKDIR}"

do_install() {
    # Stage under datadir — auditd owns /etc/audit and /etc/audit/rules.d, so we
    # cannot package into those directories directly. iotgw-rootfs.bbclass deploys
    # the rules into the image rootfs via ROOTFS_POSTPROCESS_COMMAND.
    install -d ${D}${datadir}/iotgw-audit
    install -m 0640 ${WORKDIR}/audit.rules ${D}${datadir}/iotgw-audit/iotgw.rules
}

FILES:${PN} = "${datadir}/iotgw-audit/iotgw.rules"
