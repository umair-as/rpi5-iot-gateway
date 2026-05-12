DESCRIPTION = "IoT Gateway Mainline Linux Kernel"
SECTION = "kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${S}/COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

inherit kernel
inherit iotgw-kernel-fragments
require recipes-kernel/linux/linux-yocto.inc

LINUX_VERSION_EXTENSION = ""
PV = "${LINUX_VERSION}+git${SRCPV}"

# Pinned revisions for reproducible CI/release builds. Kept in the shared
# .inc so the three providers (mainline, mainline-fit, mainline-recovery)
# cannot drift apart. SRCREV_machine tracks the tip of linux-6.18.y at
# the time of the bump.
SRCREV_machine = "d31a849ff5011dad5c271b53819a0b279e367d68"
SRCREV_meta = "307ef96123620278563ff5b1c9fb8b7b4da26970"
SRCREV_FORMAT = "machine_meta"
SRCPV = "${@bb.fetch2.get_srcrev(d)}"

KCONFIG_MODE = "--alldefconfig"
KBUILD_DEFCONFIG:raspberrypi5 ?= "defconfig"

COMPATIBLE_MACHINE = "^raspberrypi5$"
DEPENDS:append = "${@' pahole-native' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
KERNEL_DEBUG = "${@'True' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Gate Raspberry Pi firmware RTC backport for easy A/B build testing.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Keep this baseline recipe minimal for initial bring-up.
KERNEL_FEATURES:remove = "features/debug/printk.scc"
KERNEL_FEATURES:remove = "features/kernel-sample/kernel-sample.scc"

# Temporary bring-up workaround:
# Scarthgap's symbol_why/kconfiglib stack can fail on newer Kconfig syntax
# (e.g. "transitional" in Linux 6.18), so skip configcheck for this provider.
do_kernel_configcheck[noexec] = "1"

# Mainline 6.18 doesn't provide the full CM5 DTB set expected by
# meta-raspberrypi's raspberrypi5 machine config. Limit DTB build
# to the one known-available board target for initial bring-up.
KERNEL_DEVICETREE:raspberrypi5 = "broadcom/bcm2712-rpi-5-b.dtb"

SRC_URI:append = "${@' file://0001-rtc-rtc-rpi-add-simple-RTC-driver-for-Raspberry-Pi.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = "${@' file://0002-arm64-dts-broadcom-bcm2712-add-rpi-rtc-node.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = "${@' file://0003-arm64-dts-broadcom-rp1-common-add-RP1-SPI0-controller.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
SRC_URI:append = "${@' file://0004-arm64-dts-broadcom-bcm2712-rpi-5-b-add-TPM-on-RP1-SPI0-CS1.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
SRC_URI:append = " file://0005-arm64-dts-broadcom-bcm2712-add-avs-thermal-zone.patch"
SRC_URI:append = "${@' file://0006-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"
SRC_URI:append = "${@' file://0007-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch' if d.getVar('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE') == '1' else ''}"
SRC_URI:append = "${@' file://0008-mfd-bcm2835-pm-Add-support-for-BCM2712.patch' if d.getVar('IOTGW_ENABLE_HW_WATCHDOG') == '1' else ''}"
SRC_URI:append = "${@' file://0009-arm64-dts-broadcom-bcm2712-add-pm-watchdog-node.patch' if d.getVar('IOTGW_ENABLE_HW_WATCHDOG') == '1' else ''}"
SRC_URI:append = "${@' file://0010-pmdomain-bcm-bcm2835-power-Add-support-for-BCM2712.patch' if d.getVar('IOTGW_ENABLE_HW_WATCHDOG') == '1' else ''}"
SRC_URI:append = " file://fragments/thermal-rpi5.cfg"
