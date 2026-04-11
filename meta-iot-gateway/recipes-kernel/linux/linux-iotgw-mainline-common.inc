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

KCONFIG_MODE = "--alldefconfig"
KBUILD_DEFCONFIG:raspberrypi5 ?= "defconfig"

COMPATIBLE_MACHINE = "^raspberrypi5$"

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
SRC_URI:append = " file://fragments/thermal-rpi5.cfg"
