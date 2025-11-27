SUMMARY = "RAUC bundle (rootfs-only) for IoT GW images"
DESCRIPTION = "Produces a RAUC bundle (.raucb) that updates only the rootfs slot. Select image via BUNDLE_IMAGE_NAME."

# Common bundle settings
require iot-gw-bundle-common.inc

# Select the image to bundle from environment (fallback to standard image)
# Use lazy expansion so env overrides (via BB_ENV_PASSTHROUGH_ADDITIONS) take effect
BUNDLE_IMAGE_NAME ?= "iot-gw-image-dev"
BUNDLE_IMAGE = "${BUNDLE_IMAGE_NAME}"

# Rootfs-only bundles do not update /boot
IOTGW_RAUC_UPDATE_BOOTFILES = "0"

# Artifact basename
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME = "${BUNDLE_BASENAME}"
