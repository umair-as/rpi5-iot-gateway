FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# fstab matches our WKS layout (A/B slots + LABEL=data)
# Set custom hostname
# Note: issue/motd are shipped by iotgw-banner.
SRC_URI += "file://fstab file://hostname file://hosts file://profile.d/10-iotgw-path.sh file://skel/.bashrc"

# Mount point for the persistent data partition. Must exist in the read-only
# rootfs — systemd cannot mkdir it at mount time.
dirs755 += "/data"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/fstab ${D}${sysconfdir}/fstab
    install -m 0644 ${UNPACKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${UNPACKDIR}/hosts ${D}${sysconfdir}/hosts

    # iotgw-banner owns the login-banner surfaces; base-files must not also
    # package them or the rootfs transaction fails on file conflicts.
    rm -f ${D}${sysconfdir}/issue ${D}${sysconfdir}/issue.net ${D}${sysconfdir}/motd
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/profile.d/10-iotgw-path.sh ${D}${sysconfdir}/profile.d/10-iotgw-path.sh
    install -d ${D}${sysconfdir}/skel
    install -m 0644 ${UNPACKDIR}/skel/.bashrc ${D}${sysconfdir}/skel/.bashrc
    install -d ${D}/root
    install -m 0644 ${UNPACKDIR}/skel/.bashrc ${D}/root/.bashrc
    install -d ${D}/uboot-env

    # Create uninitialized machine-id file.
    # Runtime persistence/bind behavior is handled by iotgw-machine-id service.
    touch ${D}${sysconfdir}/machine-id
    chmod 0444 ${D}${sysconfdir}/machine-id
}
