FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Provide improved grow-partition unit and script
SRC_URI:append = " \
    file://rauc-grow-data-partition.service \
    file://grow-data-partition.sh \
    file://managed-paths.conf \
    file://managed-paths.d/network.conf \
    file://managed-paths.d/observability.conf \
    file://overlay-reconcile.py \
"

# grow-data-partition.sh requires bash/e2fsprogs plus util-linux (lsblk, partprobe),
# udev (udevadm), and sgdisk for GPT backup header relocation.
RDEPENDS:${PN}-grow-data-part:append = " bash e2fsprogs util-linux udev gptfdisk"

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
    install -d ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d
    install -m 0644 ${WORKDIR}/managed-paths.d/network.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d/network.conf
    install -m 0644 ${WORKDIR}/managed-paths.d/observability.conf \
        ${D}${datadir}/iotgw/overlay-reconcile/managed-paths.d/observability.conf

    # Install Python overlay reconciler invoked by bundle hooks.
    install -d ${D}${libexecdir}/rauc
    install -m 0755 ${WORKDIR}/overlay-reconcile.py \
        ${D}${libexecdir}/rauc/overlay-reconcile.py
}

# Ensure the script is placed with the grow subpackage
FILES:rauc-grow-data-part:append = " ${sbindir}/grow-data-partition.sh"
FILES:${PN}-service:append = " ${datadir}/iotgw/overlay-reconcile/managed-paths.conf ${datadir}/iotgw/overlay-reconcile/managed-paths.d/network.conf ${datadir}/iotgw/overlay-reconcile/managed-paths.d/observability.conf ${libexecdir}/rauc/overlay-reconcile.py"
RDEPENDS:${PN}-service:append = " python3-core"

# Keep RAUC available for D-Bus activation, but don't start it by default
SYSTEMD_AUTO_ENABLE:${PN}-service = "disable"
