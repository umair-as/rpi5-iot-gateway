FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Provide improved grow-partition unit and script
SRC_URI:append = " \
    file://rauc-grow-data-partition.service \
    file://grow-data-partition.sh \
    file://managed-paths.conf \
"

# grow-data-partition.sh requires bash/e2fsprogs plus util-linux (lsblk, partprobe)
# and udev (udevadm).
RDEPENDS:${PN}-grow-data-part:append = " bash e2fsprogs util-linux udev"

do_install:append() {
    # Override unit with our hardened version
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rauc-grow-data-partition.service \
        ${D}${systemd_system_unitdir}/rauc-grow-data-partition.service

    # Install grow helper script used by the unit
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/grow-data-partition.sh \
        ${D}${sbindir}/grow-data-partition.sh

    # Install managed overlay reconciliation metadata consumed by bundle hooks.
    install -d ${D}${datadir}/iotgw/overlay-reconcile
    install -m 0644 ${WORKDIR}/managed-paths.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.conf
}

# Ensure the script is placed with the grow subpackage
FILES:rauc-grow-data-part:append = " ${sbindir}/grow-data-partition.sh"
FILES:${PN}-service:append = " ${datadir}/iotgw/overlay-reconcile/managed-paths.conf"

# Keep RAUC available for D-Bus activation, but don't start it by default
SYSTEMD_AUTO_ENABLE:${PN}-service = "disable"
