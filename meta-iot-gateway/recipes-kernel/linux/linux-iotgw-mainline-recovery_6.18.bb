require recipes-kernel/linux/linux-iotgw-mainline-common.inc

SUMMARY = "IoT Gateway Mainline Linux Recovery Kernel"

LINUX_VERSION ?= "6.18+"
KERNEL_VERSION_SANITY_SKIP = "1"
PV = "${LINUX_VERSION}+git${SRCPV}"

BRANCH ?= "linux-6.18.y"
KMETA = "kernel-meta"

# Keep source revisions aligned with the primary kernel provider.
SRCREV_machine = "25e0b1c206e3def1bd3bf9dcba980c5138c637a9"
SRCREV_meta = "307ef96123620278563ff5b1c9fb8b7b4da26970"
SRCREV_FORMAT = "machine_meta"
SRCPV = "${@bb.fetch2.get_srcrev(d)}"

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;name=machine;branch=${BRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.6;destsuffix=${KMETA};protocol=https \
"

# This recipe is a build-time artifact source for FIT kernel-2 and must not
# compete as a virtual/kernel provider.
PROVIDES:remove = "virtual/kernel"
KERNEL_PACKAGE_NAME = "kernel-recovery"

# Keep recovery kernel module ABI compatible with production rootfs modules.
# This recipe boots the same rootfs, so kernel feature set must match the
# production feature profile to avoid module load failures.
IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_observability_dev igw_security_prod"

# Optional recovery initramfs bundling. Default OFF to avoid circular
# dependencies with FIT flow kernel packaging graph.
IOTGW_RECOVERY_INITRAMFS ?= "0"
INITRAMFS_IMAGE = "${@'iot-gw-image-recovery-initramfs' if d.getVar('IOTGW_RECOVERY_INITRAMFS') == '1' else ''}"
INITRAMFS_IMAGE_BUNDLE = "${@'1' if d.getVar('IOTGW_RECOVERY_INITRAMFS') == '1' else '0'}"
KERNEL_IMAGETYPE:fitflow:pn-linux-iotgw-mainline-recovery = "Image"
KERNEL_IMAGETYPE:pn-linux-iotgw-mainline-recovery:fitflow = "Image"
KERNEL_CLASSES:fitflow:pn-linux-iotgw-mainline-recovery = ""
KERNEL_CLASSES:pn-linux-iotgw-mainline-recovery:fitflow = ""

do_deploy:append() {
    src_image="${B}/arch/${ARCH}/boot/Image"
    [ -e "${src_image}" ] || bbfatal "recovery kernel image not found: ${src_image}"
    install -m 0644 "${src_image}" "${DEPLOYDIR}/linux-recovery.bin"
}
