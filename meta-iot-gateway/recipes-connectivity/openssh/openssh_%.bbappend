FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# sshd runs as one long-lived daemon (sshd.service, "sshd -D"), the way Fedora
# and RHEL ship it, instead of socket activation with a per-connection
# sshd@.service. Reasons:
#   * sshd owns its listener, so ListenAddress/AddressFamily, MaxStartups and
#     PerSourcePenalties take effect; under "sshd -i" they are read and ignored.
#   * no per-connection unit to sandbox: an admin session runs in the host's
#     mount namespace with the real /etc, /tmp and /run, and SELinux (sshd_t ->
#     staff_t/sysadm_t) is what confines it.
#   * the unit is OE-Core's own sshd.service (Type=notify-reload: the built sshd
#     sends READY=1/RELOADING=1 to $NOTIFY_SOCKET), so no unit is forked here.
PACKAGECONFIG:remove = "systemd-sshd-socket-mode"
PACKAGECONFIG:append = " systemd-sshd-service-mode"

SRC_URI:append = " file://iotgw-sshd-keys.sh \
                   file://iotgw-sshd-keys.service \
                   file://05-iotgw-listen.conf \
                   file://iotgw-pam-sshd \
                 "

do_install:append() {
    # sshd reads its host keys from /run/sshd-keys, filled before sshd starts by
    # iotgw-sshd-keys.service: copied from the persistent /data/ssh, or
    # generated for that boot only when /data is unavailable, so a degraded boot
    # still has SSH (restricted recovery mode). sshd_check_keys
    # (sshdgenkeys.service) derives the key paths from the HostKey directives of
    # the -f config (sshd_config_readonly, via SSHD_OPTS), so it checks the same
    # files and finds them present; SYSCONFDIR in /etc/default/ssh is only a
    # runtime scratch dir.
    if [ -f ${D}${sysconfdir}/ssh/sshd_config_readonly ]; then
        sed -i '/^HostKey /d' ${D}${sysconfdir}/ssh/sshd_config_readonly
        {
            echo "HostKey /run/sshd-keys/ssh_host_rsa_key"
            echo "HostKey /run/sshd-keys/ssh_host_ecdsa_key"
            echo "HostKey /run/sshd-keys/ssh_host_ed25519_key"
        } >> ${D}${sysconfdir}/ssh/sshd_config_readonly
    fi
    install -d ${D}${libexecdir}/iotgw ${D}${systemd_system_unitdir}
    install -m 0755 ${UNPACKDIR}/iotgw-sshd-keys.sh ${D}${libexecdir}/iotgw/iotgw-sshd-keys
    install -m 0644 ${UNPACKDIR}/iotgw-sshd-keys.service ${D}${systemd_system_unitdir}/

    # Pin the listener to IPv4. This rides inside openssh-sshd rather than a
    # separate hardening package on purpose: the listen scope must not depend
    # on an image recipe remembering to install a security package.
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/05-iotgw-listen.conf \
        ${D}${sysconfdir}/ssh/sshd_config.d/05-iotgw-listen.conf

    # PAM stack in Fedora's order (pam_selinux close, pam_loginuid,
    # pam_selinux open, then the user-context session modules). Replaces the
    # meta-selinux stack, which runs pam_keyinit before pam_selinux open and so
    # creates the session keyring in sshd_t instead of the user's context.
    if ${@bb.utils.contains('DISTRO_FEATURES', 'pam', 'true', 'false', d)}; then
        install -m 0644 ${UNPACKDIR}/iotgw-pam-sshd ${D}${sysconfdir}/pam.d/sshd
    fi
}

FILES:${PN}-sshd:append = " ${libexecdir}/iotgw/iotgw-sshd-keys \
                            ${systemd_system_unitdir}/iotgw-sshd-keys.service \
                            ${sysconfdir}/ssh/sshd_config.d/05-iotgw-listen.conf \
                          "
SYSTEMD_SERVICE:${PN}-sshd:append = " iotgw-sshd-keys.service"

# ssh-keygen, mountpoint and cp for iotgw-sshd-keys.
RDEPENDS:${PN}-sshd:append = " ${PN}-keygen util-linux-mountpoint coreutils"

# Every module named in iotgw-pam-sshd, so a missing plugin cannot turn a
# "required" line into a refused login. OE-Core already adds keyinit and
# loginuid; the rest arrive today only through other recipes' RDEPENDS.
RDEPENDS:${PN}-sshd:append = " ${@bb.utils.contains('DISTRO_FEATURES', 'pam', \
    'pam-plugin-nologin pam-plugin-env pam-plugin-limits pam-plugin-motd pam-plugin-unix', '', d)} \
    ${@bb.utils.contains('DISTRO_FEATURES', 'pam selinux', 'pam-plugin-selinux', '', d)}"
