FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://openssh-hostkeys.tmpfiles.conf"

do_install:append() {
    # For read-only-rootfs profile, OE-Core points sshd_config_readonly HostKey
    # to /var/run/ssh (volatile), forcing key regeneration every boot.
    # Move host keys to /var/lib/ssh so sshdgenkeys is one-time.
    if [ -f ${D}${sysconfdir}/ssh/sshd_config_readonly ]; then
        sed -i '/^HostKey /d' ${D}${sysconfdir}/ssh/sshd_config_readonly
        {
            echo "HostKey /var/lib/ssh/ssh_host_rsa_key"
            echo "HostKey /var/lib/ssh/ssh_host_ecdsa_key"
            echo "HostKey /var/lib/ssh/ssh_host_ed25519_key"
        } >> ${D}${sysconfdir}/ssh/sshd_config_readonly
    fi

    # Keep sshd_check_keys target directory aligned with readonly sshd config.
    if [ -f ${D}${sysconfdir}/default/ssh ]; then
        # Upstream default points to volatile /var/run/ssh on RO rootfs setups.
        # Rewrite to persistent /var/lib/ssh so key generation is one-time.
        sed -i -e 's#/var/run/ssh#/var/lib/ssh#g' -e 's#/run/ssh#/var/lib/ssh#g' \
            ${D}${sysconfdir}/default/ssh
    fi

    # Ensure persistent host key directory exists with strict permissions.
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/openssh-hostkeys.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/openssh-hostkeys.conf
}

FILES:${PN}-sshd:append = " ${sysconfdir}/tmpfiles.d/openssh-hostkeys.conf"
