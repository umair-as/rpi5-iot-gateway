SUMMARY = "IoT GW Image for Raspberry Pi 5"
DESCRIPTION = "Complete IoT Gateway image with MQTT and diagnostics"

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Variant-specific features
IMAGE_FEATURES += " \
    tools-debug \
    package-management \
"

# Variant-specific packages
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-devtools \
    packagegroup-core-full-cmdline \
    sudo \
    shadow \
    bridge-utils \
    avahi-daemon \
    tmux \
    btop \
"
