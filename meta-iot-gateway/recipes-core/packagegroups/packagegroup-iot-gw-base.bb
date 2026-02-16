SUMMARY = "IoT GW Base package group"
DESCRIPTION = "Base runtime packages and hardware tools common to all images"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    packagegroup-iot-gw-utils \
    sudo \
    networkmanager \
    systemd-analyze \
    lynis \
    ota-certs \
    ota-updater \
"

# Avoid allarch + dynamically renamed library deps (e.g., libgpiod -> libgpiod3)
# Pulling lib via tools keeps this allarch-safe.
