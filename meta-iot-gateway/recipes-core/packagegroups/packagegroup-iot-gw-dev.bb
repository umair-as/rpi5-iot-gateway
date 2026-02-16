SUMMARY = "IoT GW Development package group"
DESCRIPTION = "Developer tooling layered on top of base/apps"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    packagegroup-iot-gw-devtools \
    packagegroup-core-buildessential \
    gdb \
    gdbserver \
    ltrace \
    valgrind \
    perf \
    wireshark \
    htop \
    kernel-hardening-checker \
    ota-certs-devca \
"

# Optional: container runtime tools (opt-in)
RDEPENDS:${PN} += "${@bb.utils.contains('IOTGW_ENABLE_CONTAINERS','1',' packagegroup-iot-gw-containers','',d)}"
