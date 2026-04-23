SUMMARY = "IoT GW Base package group"
DESCRIPTION = "Base runtime packages and hardware tools common to all images"
LICENSE = "MIT"

inherit packagegroup

# Manual OTA workflow in use: rauc install <bundle-url>
# Keep ota-updater excluded unless periodic polling is explicitly required.
RDEPENDS:${PN} = " \
    packagegroup-iot-gw-utils \
    iotgw-bootstage \
    sudo \
    networkmanager \
    systemd-analyze \
    systemd-extra-utils \
    lynis \
    ota-certs \
    ${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE','pkcs11',' %s' % (d.getVar('IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES') or ''),'',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672','1',' cryptsetup','',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672','1',' iotgw-tpm-policy tpm-ops iotgw-tpm-health','',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_ENCRYPTED_STORE_DEV','1',' iotgw-encrypted-store','',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_OBSERVABILITY','1',' packagegroup-iot-gw-observability','',d)} \
"

# Avoid allarch + dynamically renamed library deps (e.g., libgpiod -> libgpiod3)
# Pulling lib via tools keeps this allarch-safe.
