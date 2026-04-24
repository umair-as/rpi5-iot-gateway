FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Base hardening: Kconfig-validated defconfig patch replaces the old iotgw-uboot.cfg
# fragment. Produced via savedefconfig after merging iotgw-uboot.cfg on top of
# upstream rpi_arm64_defconfig — captures resolved Kconfig dependencies.
SRC_URI:append = " file://0003-defconfig-iotgw-base.patch file://fw_env.config file://0001-rpi-env-minimize-boot-scanning-for-iot-gateway.patch file://0002-rpi-iotgw-appliance-fast-path-and-netboot-gate.patch"

# ── U-Boot feature gating (mirrors IOTGW_KERNEL_FEATURES / iotgw-kernel-fragments.bbclass) ──

IOTGW_UBOOT_FEATURES ?= "surface_reduce"

# surface_reduce: disable unused commands (safe for dev and prod)
SRC_URI:append = "${@' file://iotgw-uboot-hardening.cfg' \
    if 'surface_reduce' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# fit_enforce: require signed FIT, disable legacy image format (all variants)
SRC_URI:append = "${@' file://iotgw-uboot-fit-enforce.cfg' \
    if 'fit_enforce' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# appliance_lockdown: production prompt/env lockdown
SRC_URI:append = "${@' file://iotgw-uboot-prod.cfg' \
    if 'appliance_lockdown' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# ── Production key guard ─────────────────────────────────────────────────────
inherit iotgw-uboot-prod-key-guard

# ── Boot delay override ──────────────────────────────────────────────────────
# meta-raspberrypi forces BOOTDELAY=-2 via do_configure:append:raspberrypi5
# to work around a UART-less hang when no debug UART is connected
# (https://bugzilla.opensuse.org/show_bug.cgi?id=1251192,
#  https://lists.denx.de/pipermail/u-boot/2025-January/576305.html).
# We override with IOTGW_UBOOT_BOOTDELAY so dev builds get the 2s keyed
# autoboot window (type 'igw' to stop) while prod keeps -2.
IOTGW_UBOOT_BOOTDELAY ?= "2"
IOTGW_UBOOT_BOOTDELAY:pn-u-boot = "${@ '-2' if 'appliance_lockdown' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else '2'}"

do_configure:append:raspberrypi5() {
    sed -i '/^CONFIG_BOOTDELAY=/d' "${B}/.config"
    echo "CONFIG_BOOTDELAY=${IOTGW_UBOOT_BOOTDELAY}" >> "${B}/.config"
    bbnote "iotgw: BOOTDELAY=${IOTGW_UBOOT_BOOTDELAY}"
}

do_install:append() {
    # Override fw_env.config from lower-priority layers.
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

