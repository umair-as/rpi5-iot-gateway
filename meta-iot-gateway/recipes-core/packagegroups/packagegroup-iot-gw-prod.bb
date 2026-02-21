SUMMARY = "IoT GW Production package group"
DESCRIPTION = "Production-focused additions layered on top of base/apps"
LICENSE = "MIT"

inherit packagegroup

# Manual OTA workflow in use: rauc install <bundle-url>
# Keep ota-updater excluded unless periodic polling is explicitly required.
RDEPENDS:${PN} = " \
    ota-certs \
"
