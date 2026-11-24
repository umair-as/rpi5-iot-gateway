DESCRIPTION = "IoT Gateway Mainline Linux Kernel"
SECTION = "kernel"
HOMEPAGE = "https://www.kernel.org/"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${S}/COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

inherit kernel
inherit iotgw-kernel-fragments
# Persistent CONFIG_MODULE_SIG_KEY (opt-in via IOTGW_MODULE_SIG_KEY_FILE).
# Inherited AFTER iotgw-kernel-fragments so its do_configure postfunc sees
# the merged .config.
inherit iotgw-kernel-module-sig-key
require recipes-kernel/linux/linux-yocto.inc

LINUX_VERSION_EXTENSION = ""
PV = "${LINUX_VERSION}+git"

# CVE identity for cve-check/sbom-cve-check. kernel.bbclass defaults
# CVE_PRODUCT to "linux_kernel linux:linux"; the trailing "linux:linux" token
# over-matches unrelated "linux" NVD products and yields false positives, so
# pin to the canonical kernel CPE only. CVE_VERSION defaults to PV, whose
# "+git" suffix breaks NVD version-range comparison — feed the clean
# upstream release (e.g. 6.18.37) instead so fixed-below CVEs aren't flagged.
CVE_PRODUCT = "linux_kernel"
CVE_VERSION = "${LINUX_VERSION}"

# Pinned revision for reproducible CI/release builds. SRCREV_machine tracks a
# released linux-6.18.y tag (not the moving branch tip): v6.18.65. Floor
# v6.18.37: it carries the Bluetooth close-path use-after-free fixes (the .34
# hci_uart / l2cap / ISO / hci_conn / bnep batch) that close the
# hci_sock_release -> sk_destruct -> reuseport UAF on HCI-socket close.
# Bump LINUX_VERSION (linux-iotgw-mainline_6.18.bb) with it.
# SRCREV_meta pins yocto-kernel-cache on the branch matching the kernel
# series (yocto-6.18); move both together on a series change.
SRCREV_machine = "4700e3adf3b24b39dd4929e9c6d62811ba3ccea8"
SRCREV_meta = "03eefba5e2b51af531fee31cf9705613a45d3688"
SRCREV_FORMAT = "machine_meta"

KCONFIG_MODE = "--alldefconfig"
KBUILD_DEFCONFIG:raspberrypi5 ?= "defconfig"

COMPATIBLE_MACHINE = "^raspberrypi5$"
DEPENDS:append = "${@' pahole-native' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
KERNEL_DEBUG = "${@'True' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Gate Raspberry Pi firmware RTC backport for easy A/B build testing.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Keep this baseline provider minimal.
KERNEL_FEATURES:remove = "features/debug/printk.scc"
KERNEL_FEATURES:remove = "features/kernel-sample/kernel-sample.scc"

# kernel-yocto's config audit is not a usable gate for 6.18. Its symbol_why.py
# runs on kern-tools' kconfiglib, which does not parse 6.18 Kconfig on its own
# ($(error-if ...)); inside the task it runs, but at KCONF_AUDIT_LEVEL 1 it
# reports nothing for a config that has lost requested options, and even
# unclassified it omits requests dropped for an unmet dependency. The layer's
# fragment requests are enforced by iotgw-kernel-fragments.bbclass
# (iotgw_fragment_gate) instead.
do_kernel_configcheck[noexec] = "1"

# Mainline 6.18 doesn't provide the full CM5 DTB set expected by
# meta-raspberrypi's raspberrypi5 machine config. Limit the DTB build to the one
# board target mainline 6.18 provides.
KERNEL_DEVICETREE:raspberrypi5 = "broadcom/bcm2712-rpi-5-b.dtb"

SRC_URI:append = "${@' file://0001-rtc-rtc-rpi-add-simple-RTC-driver-for-Raspberry-Pi.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = "${@' file://0002-arm64-dts-broadcom-bcm2712-add-rpi-rtc-node.patch' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
SRC_URI:append = " file://0005-arm64-dts-broadcom-bcm2712-add-avs-thermal-zone.patch"
SRC_URI:append = "${@' file://0006-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"
SRC_URI:append = "${@' file://0007-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch' if d.getVar('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE') == '1' else ''}"
# Fixed MMC numbering: the SD card is mmc0 whatever the probe order, so
# /dev/mmcblk0 on the verity command line and in the RAUC rules is stable.
SRC_URI:append = " file://0008-arm64-dts-broadcom-bcm2712-rpi-5-b-add-mmc-aliases.patch"
# The TPM node goes last among the bcm2712-rpi-5-b.dts patches: it appends at
# the end of the file, so the unconditional patches before it apply whether or
# not the TPM is enabled.
SRC_URI:append = "${@' file://0003-arm64-dts-broadcom-rp1-common-add-RP1-SPI0-controller.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
SRC_URI:append = "${@' file://0004-arm64-dts-broadcom-bcm2712-rpi-5-b-add-TPM-on-RP1-SPI0-CS1.patch' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"
# V3D GPU on BCM2712 (mainline v6.19/v7.1 backports): the power-domain and PM
# MFD support the GPU's power domain and reset need. The V3D node itself is in
# linux-6.18.y from 6.18.65 (upstream "bcm2712: Add V3D device node").
SRC_URI:append = " \
    file://0009-pmdomain-bcm-bcm2835-power-Prepare-to-support-BCM271.patch \
    file://0010-mfd-bcm2835-pm-Introduce-SoC-specific-type-identifie.patch \
    file://0011-mfd-bcm2835-pm-Add-BCM2712-PM-device-support.patch \
"
# CVE fixes with no linux-6.18.y backport yet, for code this kernel compiles:
# CVE-2026-46017 (THP deferred split queue vs migration) and CVE-2026-46153
# (8021q egress QoS map leak; 0014 is the RCU conversion 0015 builds on).
# Drop each once a 6.18.y stable release carries it.
SRC_URI:append = " \
    file://0013-mm-fix-deferred-split-queue-races-during-migration.patch \
    file://0014-8021q-use-RCU-for-egress-QoS-mappings.patch \
    file://0015-8021q-delete-cleared-egress-QoS-mappings.patch \
"
# A connected HDMI sink without a readable EDID (panel powered off, cable in)
# makes the HDMI state helper warn on every atomic check; warn once instead.
SRC_URI:append = " \
    file://0016-drm-display-hdmi-warn-once-when-the-sink-reports-no-RGB.patch \
"
# BCM2712 hardware watchdog needs no kernel patch: mainline carries BCM2712 PM
# support. bcm2835-pm matches the "brcm,bcm2712-pm" compatible (upstream
# 30ed024fb076) and bcm2712.dtsi ships the watchdog@7d200000 node with the
# "brcm,bcm2835-pm-wdt" fallback and full 0x604 reg range; the MFD registers the
# bcm2835-wdt cell (/dev/watchdog0) unconditionally. (The V3D power-domain reset
# path is GPU-only, absent from mainline, and not required by the watchdog.)
# thermal-rpi5.cfg is a recipe-specific fragment; SRC_URI is derived from
# IOTGW_KERNEL_FRAGMENTS by iotgw-kernel-fragments.bbclass.
IOTGW_KERNEL_FRAGMENTS:append = " thermal-rpi5.cfg"

# BCM2712 PCIe host bridge built in rather than modular. Unconditional: this is
# board-level correctness, not a feature. See the fragment for the boot-ordering
# evidence that motivated it.
IOTGW_KERNEL_FRAGMENTS:append = " pcie-rpi5.cfg"

# Drivers for hardware a Raspberry Pi 5 can never have, removed for every tier.
# Merged after every other fragment and shares no symbol with them; the
# fragment header lists what is deliberately kept.
IOTGW_KERNEL_FRAGMENTS:append = " surface-rpi5.cfg"

# kernel-hardening-checker report task (report-only, not in the default chain).
require ${THISDIR}/iotgw-khc-gate.inc
