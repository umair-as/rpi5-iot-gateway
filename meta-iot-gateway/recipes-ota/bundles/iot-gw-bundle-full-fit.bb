SUMMARY = "RAUC bundle (rootfs + FIT bootfiles) for IoT GW images"
DESCRIPTION = "Updates rootfs and /boot for FIT-based kernel boot flow. Select image via BUNDLE_IMAGE_NAME."

require iot-gw-bundle-common.inc

# Select the image to bundle from environment (fallback to standard image)
BUNDLE_IMAGE_NAME ?= "iot-gw-image-dev"
BUNDLE_IMAGE = "${BUNDLE_IMAGE_NAME}"

# Enable /boot updates using FIT-aware archive + hook.
IOTGW_RAUC_UPDATE_BOOTFILES = "1"
IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE = "rpi-bootfiles-archive-fit"
IOTGW_RAUC_BOOTFILES_HOOK_FILE = "bundle-hooks-fit.sh"
IOTGW_RAUC_BOOTFILES_SOURCE_FILE = "bootfiles-fit.tar.gz"
IOTGW_RAUC_BOOTFILES_BUNDLE_FILE = "bootfiles-fit.tar.gz"

BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle-full-fit"
BUNDLE_NAME = "${BUNDLE_BASENAME}"
