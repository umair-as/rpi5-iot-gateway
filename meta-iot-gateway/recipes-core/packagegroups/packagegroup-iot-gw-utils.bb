SUMMARY = "IoT GW Utilities (full, non-BusyBox)"
DESCRIPTION = "Baseline GNU/system utilities, networking, filesystems, and TLS tools for all images."
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch due to dynamic package renames across arches
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    coreutils \
    findutils \
    procps \
    grep \
    sed \
    gawk \
    diffutils \
    patch \
    gzip \
    util-linux \
    kmod \
    e2fsprogs \
    e2fsprogs-e2fsck \
    e2fsprogs-resize2fs \
    e2fsprogs-tune2fs \
    dosfstools \
    parted \
    pciutils \
    usbutils \
    iproute2 \
    iproute2-ss \
    iproute2-tc \
    iputils-ping \
    iputils-arping \
    iputils-tracepath \
    traceroute \
    iperf3 \
    curl \
    wget \
    ca-certificates \
    openssl-bin \
    linuxptp \
    less \
    file \
    which \
    rsync \
    tar \
    unzip \
    zip \
    xz \
    bzip2 \
    psmisc \
"
