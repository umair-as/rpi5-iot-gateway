SUMMARY = "Assemble Raspberry Pi boot partition into a VFAT image"
DESCRIPTION = "Creates boot.vfat containing firmware, kernel, DTBs, and U-Boot for use in RAUC boot slot."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# rpi-bootfiles (meta-raspberrypi) is COMPATIBLE_MACHINE-gated to rpi;
# match it so this recipe drops out of world on other machines.
COMPATIBLE_MACHINE = "^rpi$"

inherit deploy

DEPENDS += " \
    rpi-bootfiles \
    virtual/kernel \
    u-boot \
    dosfstools-native \
    mtools-native \
"

# Size of the boot image in MiB
BOOTIMG_SIZE_MB ?= "128"

do_deploy() {
    set -e
    install -d ${DEPLOYDIR}
    IMG=${WORKDIR}/boot.vfat
    rm -f ${IMG}

    # Create empty FAT image
    dd if=/dev/zero of=${IMG} bs=1M count=${BOOTIMG_SIZE_MB}
    mkdosfs -n boot ${IMG}

    # Ensure expected directories exist
    mmd -i ${IMG} ::/overlays || true
    mmd -i ${IMG} ::/broadcom || true

    # Copy firmware bootfiles
    if [ -d ${DEPLOY_DIR_IMAGE}/${BOOTFILES_DIR_NAME} ]; then
        mcopy -v -i ${IMG} -s ${DEPLOY_DIR_IMAGE}/${BOOTFILES_DIR_NAME}/* ::/ || true
    fi

    # Copy U-Boot binary if available
    if [ -f ${DEPLOY_DIR_IMAGE}/u-boot.bin ]; then
        mcopy -v -i ${IMG} ${DEPLOY_DIR_IMAGE}/u-boot.bin ::/u-boot.bin || true
    fi

    # Copy kernel image if present
    if [ -n "${KERNEL_IMAGETYPE}" ] && [ -f ${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE} ]; then
        mcopy -v -i ${IMG} ${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE} ::/${KERNEL_IMAGETYPE} || true
    fi

    # Copy device trees under broadcom/ (RPi firmware expects this path)
    for dtb in ${DEPLOY_DIR_IMAGE}/*.dtb; do
        if [ -f "$dtb" ]; then
            base=$(basename "$dtb")
            mcopy -v -i ${IMG} "$dtb" ::/broadcom/$base || true
        fi
    done

    # Copy overlays if present
    if [ -d ${DEPLOY_DIR_IMAGE}/overlays ]; then
        mcopy -v -i ${IMG} -s ${DEPLOY_DIR_IMAGE}/overlays/* ::/overlays/ || true
    fi

    # Optional splash if available in deploy dir
    if [ -f ${DEPLOY_DIR_IMAGE}/splash.bmp ]; then
        mcopy -v -i ${IMG} ${DEPLOY_DIR_IMAGE}/splash.bmp ::/splash.bmp || true
    fi

    install -m 0644 ${IMG} ${DEPLOYDIR}/boot.vfat
}

addtask deploy before do_build after do_install

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

