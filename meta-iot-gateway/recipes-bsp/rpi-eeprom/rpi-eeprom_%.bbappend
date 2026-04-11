FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Pin newer Raspberry Pi EEPROM payloads for Pi5 secure-boot/partition-walk fixes.
IOTGW_RPI_EEPROM_SRCREV ?= "a34ba1bcc4f46a2f4c7f3b1e806a238fdacd3698"
SRCREV = "${IOTGW_RPI_EEPROM_SRCREV}"
PV = "v2026.02.23-2712"

# Fleet policy knob for updater channel on target.
# Recommended production default is "default"; use "latest" only for controlled rollout.
IOTGW_RPI_EEPROM_RELEASE_STATUS ?= "default"

SRC_URI:append = " \
    file://0001-rpi-eeprom-update-allow-default-config-when-bootload.patch \
"

do_install:append() {
    cfg="${D}${sysconfdir}/default/rpi-eeprom-update"
    if [ -f "$cfg" ]; then
        sed -i -e "s|^FIRMWARE_RELEASE_STATUS=.*|FIRMWARE_RELEASE_STATUS=\"${IOTGW_RPI_EEPROM_RELEASE_STATUS}\"|" "$cfg"
    fi
}
