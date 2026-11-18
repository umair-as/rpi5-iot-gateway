FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Base hardening: a Kconfig-validated defconfig patch, produced via
# savedefconfig after merging the iotgw-uboot.cfg fragment on top of
# upstream rpi_arm64_defconfig — captures resolved Kconfig dependencies.
SRC_URI:append = " file://0003-defconfig-iotgw-base.patch file://0004-configs-rpi_arm64_defconfig-increase-SYS_BOOTM_LEN-for-larger-fit-kernels.patch file://fw_env.config file://0001-rpi-env-minimize-boot-scanning-for-iot-gateway.patch"

# ── U-Boot feature gating (mirrors IOTGW_KERNEL_FEATURES / iotgw-kernel-fragments.bbclass) ──

# The base default for IOTGW_UBOOT_FEATURES ("surface_reduce fit_enforce
# watchdog") is set distro-wide in conf/distro/include/iotgw-common.inc, which
# reaches this separate recipe — so no per-recipe default is duplicated here.
# fit_enforce is mandatory (signed FIT); appliance_lockdown is added on top only
# for prod (kas/uboot-prod-hardening.yml). The SRC_URI gating below keys off
# whichever tokens are present.

# surface_reduce: disable unused commands (safe for dev and prod)
SRC_URI:append = "${@' file://iotgw-uboot-hardening.cfg' \
    if 'surface_reduce' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# fit_enforce: require signed FIT, disable legacy image format (all variants)
SRC_URI:append = "${@' file://iotgw-uboot-fit-enforce.cfg' \
    if 'fit_enforce' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# watchdog: BCM2835 watchdog command/driver plus explicit IoT Gateway boot policy
SRC_URI:append = "${@' file://iotgw-uboot-watchdog.cfg file://0006-rpi-iotgw-watchdog-policy.patch' \
    if 'watchdog' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# appliance_lockdown: production prompt/env lockdown
SRC_URI:append = "${@' file://iotgw-uboot-prod.cfg' \
    if 'appliance_lockdown' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"
# CFG_ENV_FLAGS_LIST_STATIC is a C macro (not Kconfig) so the prod
# writeable-list policy must be injected via a source patch -- see
# 0005-rpi-iotgw-prod-env-flags-list-static.patch and the comment in
# iotgw-uboot-prod.cfg next to CONFIG_ENV_WRITEABLE_LIST.
SRC_URI:append = "${@' file://0005-rpi-iotgw-prod-env-flags-list-static.patch' \
    if 'appliance_lockdown' in (d.getVar('IOTGW_UBOOT_FEATURES') or '') else ''}"

# Runtime root dm-verity boot path: boot the signed per-slot FIT's own device
# tree with the environment command line cleared, so the dm-verity table in the
# FIT is what the kernel receives, and forward the firmware's board revision
# and serial to that device tree. See the patch headers for the reasoning.
#
# 0007 is authored against the tree with the watchdog policy patch applied (it
# edits the lines beside the macros that patch rewrites), so verity needs the
# `watchdog` feature that is on by default.
SRC_URI:append = " file://0007-rpi-iotgw-verity-boot-path.patch file://0008-rpi-forward-system-revision-to-kernel-fdt.patch"

python () {
    if 'watchdog' not in (d.getVar('IOTGW_UBOOT_FEATURES') or '').split():
        bb.fatal("The runtime dm-verity boot path needs the 'watchdog' token in "
                 "IOTGW_UBOOT_FEATURES: the verity boot-path patch is authored "
                 "against the tree with the watchdog policy patch applied.")
}

# ── Signing guards ───────────────────────────────────────────────────────────
# Signed-or-fail (all images): fail the build early unless an operator signing
# key is usable. Prod key guard (prod-intent only): fail unless the release DTB
# trusts ONLY the YubiKey root.
inherit iotgw-fit-signing-guard
inherit iotgw-uboot-prod-key-guard

# ── Boot delay override ──────────────────────────────────────────────────────
# meta-raspberrypi forces BOOTDELAY=-2 via do_configure:append:raspberrypi5
# to work around a UART-less hang when no debug UART is connected
# (https://bugzilla.opensuse.org/show_bug.cgi?id=1251192,
#  https://lists.denx.de/pipermail/u-boot/2025-January/576305.html).
# Re-apply the compile-time delay after it, so dev builds get the 2s keyed
# autoboot window (type 'igw' to stop) while appliance_lockdown keeps -2.
do_configure:append:raspberrypi5() {
    bootdelay="${@ '-2' if 'appliance_lockdown' in (d.getVar('IOTGW_UBOOT_FEATURES') or '').split() else '2'}"
    sed -i '/^CONFIG_BOOTDELAY=/d' "${B}/.config"
    echo "CONFIG_BOOTDELAY=${bootdelay}" >> "${B}/.config"
    bbnote "iotgw: BOOTDELAY=${bootdelay}"
}

do_install:append() {
    # Override fw_env.config from lower-priority layers.
    install -m 0644 ${UNPACKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}
