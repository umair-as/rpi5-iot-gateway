## Common base include for IoT Gateway images (RPi5)

# Core inheritance shared by all image variants
inherit core-image iotgw-rootfs extrausers
inherit iotgw-rauc-image

# Include centralized user/group definitions
require iotgw-users.inc

# Avoid redundant image formats
IMAGE_FSTYPES:remove = "ext3"

# Common baseline features
IMAGE_FEATURES += " \
    ssh-server-openssh \
    splash \
"

# Common packages across all variants
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-base \
    packagegroup-iot-gw-hwtools \
    packagegroup-iot-gw-apps \
    iotgw-banner \
    iotgw-network-profiles \
    iotgw-sysctl \
    iotgw-journald \
    iotgw-firewall \
    iotgw-systemd-presets \
    iotgw-provision \
    iotgw-sudoers \
    nftables \
    figlet \
    wpa-supplicant \
    networkmanager-wifi \
    kernel-modules \
    linux-firmware-rpidistro-bcm43455 \
"
