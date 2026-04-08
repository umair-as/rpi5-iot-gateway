SUMMARY = "IoT GW Production Image (Raspberry Pi 5)"
DESCRIPTION = "Production-focused image with essential services and no development/debug extras."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Production metadata policy: do not expose build host identifier in /etc/buildinfo.
IOTGW_BUILDINFO_INCLUDE_BUILD_SYS = "0"

# Lean image features suitable for production
IMAGE_FEATURES += " \
    ssh-server-openssh \
    splash \
"

# Core functionality only
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-prod \
    ${@bb.utils.contains('IOTGW_ENABLE_OTBR','1',' otbr-rpi5','',d)} \
"

# Keep image smaller by avoiding extra free space
IMAGE_ROOTFS_EXTRA_SPACE = "524288"

# Production policy: disable U-Boot interactive stop window.
IOTGW_UBOOT_BOOTDELAY = "-2"
