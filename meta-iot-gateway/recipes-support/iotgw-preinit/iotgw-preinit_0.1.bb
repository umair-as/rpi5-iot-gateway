SUMMARY = "Pre-init that assembles /data, the SELinux policy and the writable /etc, /root, /home before systemd"
DESCRIPTION = "The boot path of every image: mounts /data (fsck first), loads \
the SELinux policy, mounts tmpfs-backed overlays on /etc and /root, binds \
/home from /data/home and the persisted machine-id, and execs systemd. A \
missing or broken /data marks the boot degraded (/run/iotgw/degraded) instead \
of failing sysinit; the degraded marker blocks OTA installs and, on a slot \
that has not yet booted healthy since its install, marking the slot good. \
Selected with init=${base_sbindir}/iotgw-preinit (usrmerge: /usr/sbin) on the \
signed kernel command line (iotgw-preinit-boot.inc)."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-preinit.sh \
    file://10-iotgw-degraded.conf \
    file://10-iotgw-needs-data.conf \
    file://10-iotgw-healthd-degraded.conf \
    file://iotgw-mark-good-gate.sh \
    file://10-iotgw-mark-good-gate.conf \
    file://iotgw-var-volatile-relabel.tmpfiles.conf \
    file://systemd-timesyncd-after-volatile-lib.conf \
"

S = "${UNPACKDIR}"

inherit features_check
REQUIRED_DISTRO_FEATURES = "systemd"

do_install() {
    install -d ${D}${base_sbindir}
    install -m 0755 ${UNPACKDIR}/iotgw-preinit.sh ${D}${base_sbindir}/iotgw-preinit

    # OTA installs need /data; refuse them on a degraded boot.
    install -d ${D}${systemd_system_unitdir}/ota-updater.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-degraded.conf \
        ${D}${systemd_system_unitdir}/ota-updater.service.d/10-iotgw-degraded.conf

    # Restricted recovery mode: units whose state exists only on /data are
    # skipped without it; edge-healthd runs without its state dir so it can
    # report the degraded boot.
    for u in ota-certs-provision.service; do
        install -d ${D}${systemd_system_unitdir}/$u.d
        install -m 0644 ${UNPACKDIR}/10-iotgw-needs-data.conf \
            ${D}${systemd_system_unitdir}/$u.d/10-iotgw-needs-data.conf
    done
    install -d ${D}${systemd_system_unitdir}/edge-healthd.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-healthd-degraded.conf \
        ${D}${systemd_system_unitdir}/edge-healthd.service.d/10-iotgw-degraded.conf

    # A degraded boot of a slot still on trial after its install is not
    # marked good; every other boot is.
    install -d ${D}${libexecdir}/iotgw
    install -m 0755 ${UNPACKDIR}/iotgw-mark-good-gate.sh ${D}${libexecdir}/iotgw/iotgw-mark-good-gate
    install -d ${D}${systemd_system_unitdir}/rauc-mark-good.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-mark-good-gate.conf \
        ${D}${systemd_system_unitdir}/rauc-mark-good.service.d/10-iotgw-mark-good-gate.conf

    # Relabel the volatile /var/volatile tmpfs root after policy load.
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iotgw-var-volatile-relabel.tmpfiles.conf \
        ${D}${sysconfdir}/tmpfiles.d/iotgw-var-volatile-relabel.conf

    # Order timesyncd after the volatile-binds /var/lib so its StateDirectory
    # can be created (no early 238/STATE_DIRECTORY failures).
    install -d ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d
    install -m 0644 ${UNPACKDIR}/systemd-timesyncd-after-volatile-lib.conf \
        ${D}${systemd_system_unitdir}/systemd-timesyncd.service.d/10-iotgw-after-volatile-lib.conf
}

FILES:${PN} = " \
    ${base_sbindir}/iotgw-preinit \
    ${systemd_system_unitdir}/ota-updater.service.d/10-iotgw-degraded.conf \
    ${systemd_system_unitdir}/ota-certs-provision.service.d/10-iotgw-needs-data.conf \
    ${systemd_system_unitdir}/edge-healthd.service.d/10-iotgw-degraded.conf \
    ${libexecdir}/iotgw/iotgw-mark-good-gate \
    ${systemd_system_unitdir}/rauc-mark-good.service.d/10-iotgw-mark-good-gate.conf \
    ${sysconfdir}/tmpfiles.d/iotgw-var-volatile-relabel.conf \
    ${systemd_system_unitdir}/systemd-timesyncd.service.d/10-iotgw-after-volatile-lib.conf \
"

# findfs, mount, mountpoint, e2fsck, timeout/cp/mv/tr (coreutils), load_policy,
# restorecon; /data growth: parted, sgdisk (gptfdisk), dumpe2fs, resize2fs.
RDEPENDS:${PN} = " \
    coreutils \
    util-linux-findfs \
    util-linux-mount \
    util-linux-mountpoint \
    util-linux-mount \
    e2fsprogs-e2fsck \
    e2fsprogs-dumpe2fs \
    e2fsprogs-resize2fs \
    parted \
    gptfdisk \
    busybox \
"
RDEPENDS:${PN} += "${@bb.utils.contains('DISTRO_FEATURES', 'selinux', 'policycoreutils-loadpolicy policycoreutils-setfiles', '', d)}"
