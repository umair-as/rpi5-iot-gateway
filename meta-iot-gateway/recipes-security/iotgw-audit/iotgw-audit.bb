SUMMARY = "IoT Gateway Audit Configuration"
DESCRIPTION = "Audit daemon configuration for security monitoring"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://audit.rules"

# Ensure auditd is present and owns /etc/audit; avoid packaging that directory here
RDEPENDS:${PN} = "auditd"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/audit/rules.d
    install -m 0640 ${WORKDIR}/audit.rules ${D}${sysconfdir}/audit/rules.d/iotgw.rules
}

FILES:${PN} = "${sysconfdir}/audit/rules.d/iotgw.rules"
