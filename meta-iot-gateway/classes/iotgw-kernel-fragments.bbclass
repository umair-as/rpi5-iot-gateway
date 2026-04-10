# Shared IoT Gateway kernel fragment policy for all kernel providers.

# Gate Raspberry Pi firmware RTC support for providers that carry the backport.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Base fragments always applied.
SRC_URI:append = " \
    file://fragments/branding.cfg \
    file://fragments/trim.cfg \
    file://fragments/storage-filesystems.cfg \
    file://fragments/ikconfig.cfg \
    file://fragments/audit.cfg \
"
SRC_URI:append = "${@' file://fragments/rtc-rpi.cfg' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"

# Optional fragments toggled via IOTGW_KERNEL_FEATURES (space/comma-separated).
SRC_URI:append = "${@' file://fragments/compute-media.cfg' if 'igw_compute_media' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/containers-cgroups.cfg' if 'igw_containers' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/networking-iot.cfg' if 'igw_networking_iot' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/observability-dev.cfg' if 'igw_observability_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/security-prod.cfg' if 'igw_security_prod' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/tpm-slb9672.cfg' if 'igw_tpm_slb9672' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/efi-surface-reduction.cfg' if 'igw_no_efi' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/selinux.cfg' if 'igw_selinux' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
SRC_URI:append = "${@' file://fragments/ima.cfg' if 'igw_ima' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Merge present fragments into the active kernel .config.
do_configure:append() {
    frags=
    if [ -d ${WORKDIR}/fragments ]; then
        frags=$(ls ${WORKDIR}/fragments/*.cfg 2>/dev/null || true)
    fi
    if [ -n "$frags" ] && [ -x ${S}/scripts/kconfig/merge_config.sh ]; then
        oe_runmake -C ${S} O=${B} olddefconfig
        ${S}/scripts/kconfig/merge_config.sh -m -O ${B} ${B}/.config $frags || die "merge_config failed"
        oe_runmake -C ${S} O=${B} olddefconfig
    fi
}
