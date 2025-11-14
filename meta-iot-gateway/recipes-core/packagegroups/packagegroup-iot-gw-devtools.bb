SUMMARY = "IoT GW Developer tools"
DESCRIPTION = "Convenient developer CLI tools (GNU coreutils, networking, tracing)."
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch due to possible dynamic package renames across arches
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    packagegroup-iot-gw-utils \
    tcpdump \
    strace \
    lsof \
    ethtool \
    vim \
    nano \
"
