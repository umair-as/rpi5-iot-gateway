SUMMARY = "IoT GW Base package group"
DESCRIPTION = "Base runtime packages and hardware tools common to all images"
LICENSE = "MIT"

inherit packagegroup

# Manual OTA workflow in use: rauc install <bundle-url>
# Keep ota-updater excluded unless periodic polling is explicitly required.
RDEPENDS:${PN} = " \
    packagegroup-iot-gw-utils \
    sudo \
    networkmanager \
    systemd-analyze \
    lynis \
    ota-certs \
    ${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672','1',' iotgw-tpm-policy tpm-ops','',d)} \
"

# Avoid allarch + dynamically renamed library deps (e.g., libgpiod -> libgpiod3)
# Pulling lib via tools keeps this allarch-safe.
