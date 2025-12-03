SUMMARY = "IoT GW Development Image (Raspberry Pi 5)"
DESCRIPTION = "Developer-focused image with debugging tools, package management, and full command-line utilities."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Image features for development
# NOTE: NOT using debug-tweaks (empty root password, insecure SSH) - secure-by-design
# Using tools-debug for gdb/strace, post-install-logging for debugging
IMAGE_FEATURES += " \
    tools-debug \
    post-install-logging \
    package-management \
"

# Core packages and developer tools
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-dev \
    packagegroup-iot-gw-security \
    packagegroup-core-buildessential \
    bridge-utils \
    avahi-daemon \
    tmux \
    btop \
    iotgw-dev-ssh-keys \
    ${@bb.utils.contains('IOTGW_ENABLE_OTBR','1',' otbr-rpi5','',d)} \
"

# Extra space for development artifacts
IMAGE_ROOTFS_EXTRA_SPACE = "1572864"
