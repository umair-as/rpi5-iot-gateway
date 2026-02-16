FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Ship base kernel config fragments (always included)
SRC_URI:append = " \
    file://fragments/branding.cfg \
    file://fragments/trim.cfg \
    file://fragments/storage-filesystems.cfg \
    file://fragments/ikconfig.cfg \
    file://fragments/audit.cfg \
"

# Optional fragments toggled via IOTGW_KERNEL_FEATURES (space/comma-separated)
# Add fragments conditionally without mutating OVERRIDES to keep metadata deterministic
SRC_URI:append = "${@' file://fragments/compute-media.cfg' if 'igw_compute_media' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/containers-cgroups.cfg' if 'igw_containers' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/networking-iot.cfg' if 'igw_networking_iot' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/observability-dev.cfg' if 'igw_observability_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/security-prod.cfg' if 'igw_security_prod' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Merge any present fragments with the base defconfig for linux-raspberrypi
do_configure:append() {
    frags=
    if [ -d ${WORKDIR}/fragments ]; then
        frags=$(ls ${WORKDIR}/fragments/*.cfg 2>/dev/null || true)
    fi
    if [ -n "$frags" ] && [ -x ${S}/scripts/kconfig/merge_config.sh ]; then
        # Ensure we have a base .config in ${B}
        oe_runmake -C ${S} O=${B} olddefconfig
        # Merge fragments
        ${S}/scripts/kconfig/merge_config.sh -m -O ${B} ${B}/.config $frags || die "merge_config failed"
        # Finalize
        oe_runmake -C ${S} O=${B} olddefconfig
    fi
}
