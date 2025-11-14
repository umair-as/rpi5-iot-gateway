SUMMARY = "IoT GW Production Image (Raspberry Pi 5)"
DESCRIPTION = "Production-focused image with essential services and no development/debug extras."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Lean image features suitable for production
IMAGE_FEATURES += " \
    ssh-server-openssh \
    splash \
"

# Core functionality only
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-prod \
"

# Keep image smaller by avoiding extra free space
IMAGE_ROOTFS_EXTRA_SPACE = "524288"
