SUMMARY = "IoT GW Base Image (Raspberry Pi 5)"
DESCRIPTION = "Standard IoT Gateway image with package management and basic tools."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Variant-specific features
IMAGE_FEATURES += " \
    package-management \
"

# Variant-specific packages
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-devtools \
    bridge-utils \
    avahi-daemon \
    tmux \
    btop \
"
