FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# Override fstab from meta-rauc-raspberrypi to match our WKS layout
# Set custom hostname
# Note: issue/motd are generated dynamically by iotgw-banner
SRC_URI += "file://fstab file://hostname file://hosts file://profile.d/10-iotgw-path.sh file://skel/.bashrc"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/fstab ${D}${sysconfdir}/fstab
    install -m 0644 ${UNPACKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${UNPACKDIR}/hosts ${D}${sysconfdir}/hosts
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
