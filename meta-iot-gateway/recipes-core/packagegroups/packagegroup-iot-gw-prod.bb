SUMMARY = "IoT GW Production package group"
DESCRIPTION = "Production-focused additions layered on top of base/apps"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    ota-certs \
    ota-updater \
"

