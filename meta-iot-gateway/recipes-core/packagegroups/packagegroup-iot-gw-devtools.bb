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
    pkgconfig \
"

# bpftool from kernel tools is reliable in our mainline flow; skip it for
# linux-raspberrypi maintenance builds where kernel tools layout differs.
RDEPENDS:${PN}:append = "${@'' if (d.getVar('PREFERRED_PROVIDER_virtual/kernel') or '').strip() == 'linux-raspberrypi' else ' bpftool'}"
