FILESEXTRAPATHS:prepend := "${THISDIR}/base-files:"

# Override fstab from meta-rauc-raspberrypi to match our 4-partition WKS layout
# Set custom hostname
# Note: issue/motd are generated dynamically by iotgw-banner
SRC_URI += "file://fstab file://hostname file://profile.d/10-iotgw-path.sh file://skel/.bashrc"

do_install:append() {
    install -m 0644 ${WORKDIR}/fstab ${D}${sysconfdir}/fstab
    install -m 0644 ${WORKDIR}/hostname ${D}${sysconfdir}/hostname
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${WORKDIR}/profile.d/10-iotgw-path.sh ${D}${sysconfdir}/profile.d/10-iotgw-path.sh
    install -d ${D}/etc/skel
    install -m 0644 ${WORKDIR}/skel/.bashrc ${D}/etc/skel/.bashrc
}
