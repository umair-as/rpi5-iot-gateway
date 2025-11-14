SUMMARY = "IoT GW Development Image (Raspberry Pi 5)"
DESCRIPTION = "Developer-focused image with debugging tools, package management, and full command-line utilities."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Image features for development
IMAGE_FEATURES += " \
    ssh-server-openssh \
    tools-debug \
    debug-tweaks \
    package-management \
    splash \
"

# Core packages and developer tools
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-dev \
    packagegroup-core-full-cmdline \
    packagegroup-core-buildessential \
    sudo \
    strace \
    gdb \
    gdbserver \
    ltrace \
    perf \
    valgrind \
    tmux \
    btop \
"

# Extra space for development artifacts
IMAGE_ROOTFS_EXTRA_SPACE = "1572864"
