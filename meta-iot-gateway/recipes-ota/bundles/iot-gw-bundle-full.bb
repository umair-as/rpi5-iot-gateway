SUMMARY = "RAUC bundle (rootfs + kernel) for IoT GW images"
DESCRIPTION = "Updates both rootfs and /boot (kernel, DTBs, overlays). Select image via BUNDLE_IMAGE_NAME."

# Common RAUC settings
require iot-gw-bundle-common.inc

# Select the image to bundle from environment (fallback to standard image)
# Use lazy expansion so env overrides (via BB_ENV_PASSTHROUGH_ADDITIONS) take effect
BUNDLE_IMAGE_NAME ?= "iot-gw-image"
BUNDLE_IMAGE = "${BUNDLE_IMAGE_NAME}"

# Enable /boot updates
IOTGW_RAUC_UPDATE_BOOTFILES = "1"

# Distinguish artifact name from rootfs-only bundle
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle-full"
BUNDLE_NAME = "${BUNDLE_BASENAME}"
