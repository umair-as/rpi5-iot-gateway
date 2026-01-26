SUMMARY = "IoT GW Desktop Image (Raspberry Pi 5, Wayland/Weston)"
DESCRIPTION = "Wayland-first desktop image using Weston compositor with full desktop environment."

LICENSE = "MIT"

# Pull in common base (RAUC, SSH, splash, baseline pkgs)
require iot-gw-image-base.inc

# Desktop environment with applications and utilities
# Includes: Weston/Wayland, Chromium browser, file manager, editors,
#           media players, system utilities, themes, and network tools
CORE_IMAGE_EXTRA_INSTALL += " packagegroup-iot-gw-desktop iotgw-dev-ssh-keys"

# Optional: Install individual sub-packages for customization
# - packagegroup-iot-gw-desktop-core     (Weston/Wayland foundation)
# - packagegroup-iot-gw-desktop-apps     (Browser, file manager, editors)
# - packagegroup-iot-gw-desktop-utils    (System utilities, network tools)
# - packagegroup-iot-gw-desktop-media    (Media players, GStreamer)
# - packagegroup-iot-gw-desktop-themes   (GTK themes and icons)

# Extra space for desktop artifacts (browser cache, user files, etc.)
# Chromium + full desktop: ~2-3GB additional recommended
IMAGE_ROOTFS_EXTRA_SPACE = "3145728"
