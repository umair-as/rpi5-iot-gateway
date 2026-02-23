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
"

# Headless-first default: avoid degraded state from static vconsole setup unit.
# Desktop profile can override this to "0" if VT keyboard setup is required.
IOTGW_DISABLE_VCONSOLE_SETUP ?= "1"

# Use only healthcheck-based mark-good flow; disable legacy one-shot unit.
IOTGW_DISABLE_RAUC_MARK_GOOD ?= "1"

# Desktop profile can include splash
IMAGE_FEATURES:append:desktop = " splash"

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
    iotgw-nftables \
    iotgw-sshd-hardening \
    nftables \
    figlet \
    wpa-supplicant \
    networkmanager-wifi \
    kernel-modules \
    linux-firmware-rpidistro-bcm43455 \
"
