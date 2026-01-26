SUMMARY = "IoT GW Desktop package group"
DESCRIPTION = "Desktop environment packages for Wayland/Weston with essential applications and utilities"
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch to support arch-specific packages
PACKAGE_ARCH = "${MACHINE_ARCH}"

PACKAGES = " \
    ${PN} \
    ${PN}-core \
    ${PN}-utils \
    ${PN}-apps \
"

# Main package pulls in all sub-packages
RDEPENDS:${PN} = " ${PN}-core ${PN}-utils ${PN}-apps"

# Core Wayland/Weston desktop foundation
# Note: Avoid direct deps on dynamically renamed libs (fontconfig, dbus, libdrm)
#       These get pulled in automatically as dependencies of other packages
RDEPENDS:${PN}-core = " \
    packagegroup-core-weston \
    weston \
    weston-examples \
    wayland-utils \
    mesa \
    xkeyboard-config \
    liberation-fonts \
    xdg-utils \
    xdg-user-dirs \
    alsa-utils \
"

# Wayland-native utilities and system integration
RDEPENDS:${PN}-utils = " \
    waybar \
    wofi \
    mako \
    wl-clipboard \
    grim \
    slurp \
    networkmanager \
    polkit \
    polkit-gnome \
    gvfs \
    udisks2 \
    udiskie \
    pavucontrol \
    hicolor-icon-theme \
    noto-fonts \
    dejavu-fonts \
"

# Applications (GTK/Wayland-friendly) with minimal deps
RDEPENDS:${PN}-apps = " \
    foot \
    pcmanfm \
    zathura \
    zathura-pdf-poppler \
"
