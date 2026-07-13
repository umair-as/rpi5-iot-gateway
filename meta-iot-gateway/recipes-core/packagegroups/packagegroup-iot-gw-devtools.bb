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
    keyutils \
    libseccomp \
    fio \
    iotop \
    lsof \
    stress-ng \
    ethtool \
    vim \
    nano \
    libmnl-dev \
    libcap-bin \
    systemd-dev \
    pkgconf \
"

# bpftool from the mainline kernel tools (linux-iotgw-mainline-fit is the only
# kernel provider).
RDEPENDS:${PN}:append = " bpftool"
