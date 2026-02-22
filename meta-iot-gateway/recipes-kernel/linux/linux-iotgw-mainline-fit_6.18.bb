require recipes-kernel/linux/linux-iotgw-mainline-common.inc

LINUX_VERSION ?= "6.18+"
KERNEL_VERSION_SANITY_SKIP = "1"
PV = "${LINUX_VERSION}+git${SRCPV}"

BRANCH ?= "linux-6.18.y"
KMETA = "kernel-meta"

# Pinned revisions for reproducible CI/release builds.
SRCREV_machine = "25e0b1c206e3def1bd3bf9dcba980c5138c637a9"
SRCREV_meta = "307ef96123620278563ff5b1c9fb8b7b4da26970"
SRCREV_FORMAT = "machine_meta"
SRCPV = "${@bb.fetch2.get_srcrev(d)}"

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;name=machine;branch=${BRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.6;destsuffix=${KMETA};protocol=https \
"

# FIT image variant: compile normal arm64 Image payload and package as fitImage.
KERNEL_IMAGETYPE = "fitImage"
KERNEL_CLASSES = " kernel-fitimage "
