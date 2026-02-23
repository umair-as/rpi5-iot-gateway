## Common RAUC bundle settings for IoT Gateway bundles

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle

# Bundle identity (matches device system.conf via rauc-conf)
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"

# Control whether to update /boot (kernel/DTBs) via bundle hook
IOTGW_RAUC_UPDATE_BOOTFILES ?= "0"
IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE ?= "rpi-bootfiles-archive"
IOTGW_RAUC_BOOTFILES_HOOK_FILE ?= "bundle-hooks.sh"
IOTGW_RAUC_BOOTFILES_SOURCE_FILE ?= "bootfiles.tar.gz"
IOTGW_RAUC_BOOTFILES_BUNDLE_FILE ?= "bootfiles.tar.gz"

# Slots included in the bundle
RAUC_BUNDLE_SLOTS = "rootfs"
# Keep adaptive updates disabled by default. Current slot image/partition size
# in this project is not 4KiB-aligned, which triggers RAUC fallback warnings:
# "Continuing after adaptive mode error ... not a multiple of 4096 bytes".
# Re-enable when partition geometry is aligned for block-hash-index mode.
IOTGW_RAUC_ADAPTIVE ?= "0"

# Use the selected image for the rootfs slot (set BUNDLE_IMAGE in variants)
RAUC_SLOT_rootfs = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype] = "ext4"
# Run pre/post hooks for update-scoped reconciliation and bootfile handling.
RAUC_SLOT_rootfs[hooks] = "pre-install;post-install"
# Optional RAUC adaptive updates (block-hash-index) to reduce rewritten data
# when installing near-identical rootfs images.
RAUC_SLOT_rootfs[adaptive] = "${@bb.utils.contains('IOTGW_RAUC_ADAPTIVE','1','block-hash-index','',d)}"

# Bundle format
RAUC_BUNDLE_FORMAT = "verity"

# Include bootfiles archive and a hook to update /boot (conditional)
RAUC_BUNDLE_EXTRA_DEPENDS += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' ${IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' ${IOTGW_RAUC_BOOTFILES_BUNDLE_FILE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES += " overlay-reconcile.py"
RAUC_BUNDLE_HOOKS[file] = "${IOTGW_RAUC_BOOTFILES_HOOK_FILE}"

# meta-rauc bundle.bbclass uses a python do_configure() task and expects plain
# filenames in RAUC_BUNDLE_EXTRA_FILES. For variant flows, normalize deploy
# artifact name into the bundle filename in WORKDIR.
python do_configure:prepend() {
    import os
    import shutil

    if d.getVar("IOTGW_RAUC_UPDATE_BOOTFILES") == "1":
        src_name = d.getVar("IOTGW_RAUC_BOOTFILES_SOURCE_FILE")
        dst_name = d.getVar("IOTGW_RAUC_BOOTFILES_BUNDLE_FILE")

        if src_name != dst_name:
            src = os.path.join(d.getVar("DEPLOY_DIR_IMAGE"), src_name)
            dst = os.path.join(d.getVar("WORKDIR"), dst_name)

            if not os.path.isfile(src):
                bb.fatal("Bootfiles source archive not found: %s" % src)

            shutil.copyfile(src, dst)
}

# Make RAUC cert and hooks available via FILESEXTRAPATHS
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:"
SRC_URI:append = " \
    file://${IOTGW_RAUC_BOOTFILES_HOOK_FILE};mode=0755 \
    file://overlay-reconcile.py;mode=0755 \
"

# Key and cert paths must be provided via local.conf or kas/local.yml
# Example in kas/local.yml.example:
#   RAUC_KEY_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-key.pem"
#   RAUC_CERT_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-cert.pem"

# Output name
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME = "${BUNDLE_BASENAME}"
