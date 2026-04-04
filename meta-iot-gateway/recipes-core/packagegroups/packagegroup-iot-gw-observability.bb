SUMMARY = "IoT GW observability stack package group"
DESCRIPTION = "Native observability stack packagegroup (InfluxDB + Telegraf)."
LICENSE = "MIT"

inherit packagegroup

PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    iotgw-observability-stack \
"
