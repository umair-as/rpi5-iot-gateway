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

# Raspberry Pi firmware passes a runtime-prepared DTB to U-Boot. Inject FIT
# public keys into deployed firmware DTBs so U-Boot control FDT can expose
# /signature and enforce FIT config signatures on target.
do_deploy:append() {
    if [ "${UBOOT_SIGN_ENABLE}" != "1" ]; then
        bbnote "FIT DTB key injection skipped: UBOOT_SIGN_ENABLE=${UBOOT_SIGN_ENABLE}"
        return
    fi

    if [ -z "${UBOOT_SIGN_KEYDIR}" ] || [ ! -d "${UBOOT_SIGN_KEYDIR}" ]; then
        bbwarn "FIT DTB key injection skipped: missing UBOOT_SIGN_KEYDIR='${UBOOT_SIGN_KEYDIR}'"
        return
    fi

    deploy_dir="${DEPLOYDIR}"
    if [ -n "${KERNEL_DEPLOYSUBDIR}" ]; then
        deploy_dir="${DEPLOYDIR}/${KERNEL_DEPLOYSUBDIR}"
    fi

    fit_path="${deploy_dir}/fitImage"
    if [ ! -e "${fit_path}" ]; then
        bbwarn "FIT DTB key injection skipped: ${fit_path} not found"
        return
    fi

    if [ -z "${RPI_KERNEL_DEVICETREE}" ]; then
        bbwarn "FIT DTB key injection skipped: RPI_KERNEL_DEVICETREE is empty"
        return
    fi

    for dtb in ${RPI_KERNEL_DEVICETREE}; do
        dtb_base="${dtb##*/}"
        dtb_path=""

        if [ -e "${deploy_dir}/${dtb_base}" ]; then
            dtb_path="${deploy_dir}/${dtb_base}"
        elif [ -e "${deploy_dir}/${dtb_base%.dtb}-${MACHINE}.dtb" ]; then
            dtb_path="${deploy_dir}/${dtb_base%.dtb}-${MACHINE}.dtb"
        else
            bbwarn "FIT DTB key injection: DTB '${dtb_base}' not found in ${deploy_dir}"
            continue
        fi

        bbnote "Injecting FIT public keys into ${dtb_path}"
        ${UBOOT_MKIMAGE_SIGN} \
            ${@'-D "${UBOOT_MKIMAGE_DTCOPTS}"' if d.getVar('UBOOT_MKIMAGE_DTCOPTS') else ''} \
            -F -k "${UBOOT_SIGN_KEYDIR}" \
            -K "${dtb_path}" \
            -r "${fit_path}" \
            ${UBOOT_MKIMAGE_SIGN_ARGS}
    done
}
