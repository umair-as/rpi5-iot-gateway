## Common RAUC bundle settings for IoT Gateway bundles

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle

# Bundle identity (matches device system.conf via rauc-conf)
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"

# Control whether to update /boot (kernel/DTBs) via bundle hook
IOTGW_RAUC_UPDATE_BOOTFILES ?= "0"

# Slots included in the bundle
RAUC_BUNDLE_SLOTS = "rootfs"

# Use the selected image for the rootfs slot (set BUNDLE_IMAGE in variants)
RAUC_SLOT_rootfs = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype] = "ext4"
# Only run post-install hook when updating /boot
RAUC_SLOT_rootfs[hooks] = "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1','post-install','',d)}"

# Bundle format
RAUC_BUNDLE_FORMAT = "verity"

# Include bootfiles archive and a hook to update /boot (conditional)
RAUC_BUNDLE_EXTRA_DEPENDS += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' rpi-bootfiles-archive','',d)}"
RAUC_BUNDLE_EXTRA_FILES += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' bootfiles.tar.gz','',d)}"
RAUC_BUNDLE_HOOKS[file] = "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1','bundle-hooks.sh','',d)}"

# Make RAUC cert and hooks available via FILESEXTRAPATHS
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:"
SRC_URI += "file://bundle-hooks.sh;mode=0755"

# Key and cert paths must be provided via local.conf or kas/local.yml
# Example in kas/local.yml.example:
#   RAUC_KEY_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-key.pem"
#   RAUC_CERT_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-cert.pem"

# Output name
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME = "${BUNDLE_BASENAME}"
