SUMMARY = "IoT Gateway Audit Configuration"
DESCRIPTION = "Audit daemon configuration for security monitoring"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://audit.rules"

# Ensure auditd is present and owns /etc/audit; avoid packaging that directory here
RDEPENDS:${PN} = "auditd"

S = "${WORKDIR}"

do_install() {
    # Install rules as data; copy into /etc via postinst to avoid dir ownership clashes with auditd
    install -d ${D}${datadir}/iotgw-audit
    install -m 0640 ${WORKDIR}/audit.rules ${D}${datadir}/iotgw-audit/iotgw.rules
}

FILES:${PN} = "${datadir}/iotgw-audit/iotgw.rules"
CONFFILES:${PN} = "${datadir}/iotgw-audit/iotgw.rules"

pkg_postinst:${PN}() {
    if [ -z "$D" ]; then
        # Ensure audit log directory exists with secure permissions
        install -d -m 0700 /var/log/audit || true
        chown root:root /var/log/audit || true
        # Deploy our rules to audit's rules.d at first boot
        mkdir -p /etc/audit/rules.d
        install -m 0640 /usr/share/iotgw-audit/iotgw.rules /etc/audit/rules.d/iotgw.rules || true
        # Enable auditd service if present
        systemctl enable auditd.service || true
        # Try to start it now if possible
        systemctl start auditd.service || true
    fi
}
