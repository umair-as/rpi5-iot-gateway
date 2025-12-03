SUMMARY = "IoT Gateway OpenSSH server hardening (dev-friendly)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-iotgw.conf"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} += "openssh-sshd"

do_install() {
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${WORKDIR}/99-iotgw.conf ${D}${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf
}

pkg_postinst:${PN}() {
    if [ -z "$D" ]; then
        conf=/etc/ssh/sshd_config
        # Ensure the drop-in directory is included by the main config
        if [ -f "$conf" ] && ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf\s*$' "$conf"; then
            echo "Include /etc/ssh/sshd_config.d/*.conf" >> "$conf"
        fi
        # Validate and reload if possible (best effort)
        if command -v sshd >/dev/null 2>&1; then
            sshd -t || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        fi
    fi
}

FILES:${PN} = "${sysconfdir}/ssh/sshd_config.d/99-iotgw.conf"

