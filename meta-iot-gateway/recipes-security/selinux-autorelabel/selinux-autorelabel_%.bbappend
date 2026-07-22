# Order the meta-selinux first-boot autorelabel after /data and the OverlayFS
# uppers are mounted. The upstream unit is Before=sysinit.target with no ordering
# against data.mount / overlayfs-setup.service, so fixfiles can run before the
# overlays exist and relabel an incomplete tree — leaving the /data-backed upper
# inodes (/etc, /var, /home, /root) unlabeled. This ships a systemd drop-in that
# adds only the ordering + mount requirement; the upstream unit is unchanged.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://10-iotgw-ordering.conf"

do_install:append() {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}/selinux-autorelabel.service.d
        install -m 0644 ${UNPACKDIR}/10-iotgw-ordering.conf \
            ${D}${systemd_system_unitdir}/selinux-autorelabel.service.d/10-iotgw-ordering.conf
    fi
}

FILES:${PN} += "${systemd_system_unitdir}/selinux-autorelabel.service.d"
