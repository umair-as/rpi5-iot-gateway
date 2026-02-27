FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# Override fstab from meta-rauc-raspberrypi to match our WKS layout
# Set custom hostname
# Note: issue/motd are generated dynamically by iotgw-banner
SRC_URI += "file://fstab file://hostname file://hosts file://profile.d/10-iotgw-path.sh file://skel/.bashrc"

do_install:append() {
    install -m 0644 ${WORKDIR}/fstab ${D}${sysconfdir}/fstab
    install -m 0644 ${WORKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${WORKDIR}/hosts ${D}${sysconfdir}/hosts
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${WORKDIR}/profile.d/10-iotgw-path.sh ${D}${sysconfdir}/profile.d/10-iotgw-path.sh
    install -d ${D}/etc/skel
    install -m 0644 ${WORKDIR}/skel/.bashrc ${D}/etc/skel/.bashrc
    install -d ${D}/uboot-env

    # Create uninitialized machine-id file
    # This signals systemd to generate a unique ID on first boot
    # The ID will be persisted via overlayfs on /data
    touch ${D}${sysconfdir}/machine-id
    chmod 0444 ${D}${sysconfdir}/machine-id
}
