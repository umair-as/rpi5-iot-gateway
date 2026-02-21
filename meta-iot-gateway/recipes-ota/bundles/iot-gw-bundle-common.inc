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

# Slots included in the bundle
RAUC_BUNDLE_SLOTS = "rootfs"

# Use the selected image for the rootfs slot (set BUNDLE_IMAGE in variants)
RAUC_SLOT_rootfs = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype] = "ext4"
# Run pre/post hooks for update-scoped reconciliation and bootfile handling.
RAUC_SLOT_rootfs[hooks] = "pre-install;post-install"

# Bundle format
RAUC_BUNDLE_FORMAT = "verity"

# Include bootfiles archive and a hook to update /boot (conditional)
RAUC_BUNDLE_EXTRA_DEPENDS += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' ${IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' bootfiles.tar.gz','',d)}"
RAUC_BUNDLE_EXTRA_FILES += " overlay-reconcile.py"
RAUC_BUNDLE_HOOKS[file] = "${IOTGW_RAUC_BOOTFILES_HOOK_FILE}"

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
