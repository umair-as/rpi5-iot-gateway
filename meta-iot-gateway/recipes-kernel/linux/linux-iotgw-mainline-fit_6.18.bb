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
    file://iotgw-fit-single.its.in \
"

# FIT image variant: compile normal arm64 Image payload and package as fitImage.
KERNEL_IMAGETYPE = "fitImage"
KERNEL_CLASSES = " kernel-fitimage "

# Phase A custom ITS path (default OFF): single kernel + single config parity.
IOTGW_FIT_CUSTOM_ITS ?= "0"
IOTGW_FIT_CUSTOM_ITS_TEMPLATE ?= "${WORKDIR}/iotgw-fit-single.its.in"
IOTGW_FIT_CUSTOM_ITS_DEFAULT_DTB ?= "broadcom/bcm2712-rpi-5-b.dtb"

do_assemble_fitimage:append() {
    if [ "${IOTGW_FIT_CUSTOM_ITS}" != "1" ]; then
        return
    fi
    if ! echo "${KERNEL_IMAGETYPES}" | grep -wq "fitImage"; then
        return
    fi

    template="${IOTGW_FIT_CUSTOM_ITS_TEMPLATE}"
    [ -r "${template}" ] || bbfatal "custom ITS template not found: ${template}"

    cd "${B}"
    linux_comp="$(uboot_prep_kimage)"
    kernel_path="${B}/linux.bin"
    [ -e "${kernel_path}" ] || bbfatal "custom ITS mode requires ${kernel_path}"

    dtb_rel="${IOTGW_FIT_CUSTOM_ITS_DEFAULT_DTB}"
    dtb_path="${B}/${KERNEL_OUTPUT_DIR}/dts/${dtb_rel}"
    if [ ! -e "${dtb_path}" ]; then
        dtb_path="${B}/${KERNEL_OUTPUT_DIR}/${dtb_rel}"
    fi
    if [ ! -e "${dtb_path}" ]; then
        bbfatal "custom ITS mode could not find DTB '${dtb_rel}' under ${B}/${KERNEL_OUTPUT_DIR}"
    fi

    dtb_name="${dtb_rel##*/}"
    conf_name="conf-${dtb_name}"
    fdt_name="fdt-${dtb_name}"
    entrypoint="${UBOOT_ENTRYPOINT}"
    if [ -n "${UBOOT_ENTRYSYMBOL}" ]; then
        entrypoint="$(${HOST_PREFIX}nm vmlinux | awk '$3=="${UBOOT_ENTRYSYMBOL}" {print "0x"$1; exit}')"
    fi
    [ -n "${entrypoint}" ] || entrypoint="${UBOOT_LOADADDRESS}"

    conf_sig_key="${UBOOT_SIGN_KEYNAME}"
    if [ -z "${conf_sig_key}" ]; then
        conf_sig_key="${UBOOT_SIGN_IMG_KEYNAME}"
    fi

    its_path="${B}/fit-image.its"
    conf_sig_fragment="${B}/fitimage-conf-signature.itsfrag"
    cp "${template}" "${its_path}"

    if [ "${UBOOT_SIGN_ENABLE}" = "1" ] && [ -n "${conf_sig_key}" ]; then
        cat > "${conf_sig_fragment}" <<EOF
                signature-1 {
                        algo = "${FIT_HASH_ALG},${FIT_SIGN_ALG}";
                        key-name-hint = "${conf_sig_key}";
                        sign-images = "fdt", "kernel";
                };
EOF
        sed -i "/__IOTGW_CONF_SIGNATURE__/r ${conf_sig_fragment}" "${its_path}"
    fi
    sed -i "s|__IOTGW_CONF_SIGNATURE__||" "${its_path}"

    sed -i \
        -e "s|@@FIT_DESC@@|${FIT_DESC}|g" \
        -e "s|@@FIT_ADDRESS_CELLS@@|${FIT_ADDRESS_CELLS}|g" \
        -e "s|@@UBOOT_ARCH@@|${UBOOT_ARCH}|g" \
        -e "s|@@UBOOT_MKIMAGE_KERNEL_TYPE@@|${UBOOT_MKIMAGE_KERNEL_TYPE}|g" \
        -e "s|@@UBOOT_LOADADDRESS@@|${UBOOT_LOADADDRESS}|g" \
        -e "s|@@UBOOT_ENTRYPOINT@@|${entrypoint}|g" \
        -e "s|@@FIT_HASH_ALG@@|${FIT_HASH_ALG}|g" \
        -e "s|@@KERNEL_COMPRESSION@@|${linux_comp}|g" \
        -e "s|@@CONF_NAME@@|${conf_name}|g" \
        -e "s|@@FDT_NAME@@|${fdt_name}|g" \
        -e "s|@@KERNEL_PATH@@|${kernel_path}|g" \
        -e "s|@@DTB_PATH@@|${dtb_path}|g" \
        "${its_path}"

    bbnote "Assembling fitImage from project-owned ITS template (${template})"
    if [ -n "${UBOOT_MKIMAGE_DTCOPTS}" ]; then
        ${UBOOT_MKIMAGE} -D "${UBOOT_MKIMAGE_DTCOPTS}" -f "${its_path}" "${B}/${KERNEL_OUTPUT_DIR}/fitImage-none"
    else
        ${UBOOT_MKIMAGE} -f "${its_path}" "${B}/${KERNEL_OUTPUT_DIR}/fitImage-none"
    fi

    if [ "${UBOOT_SIGN_ENABLE}" = "1" ]; then
        if [ -n "${UBOOT_MKIMAGE_DTCOPTS}" ]; then
            ${UBOOT_MKIMAGE_SIGN} -D "${UBOOT_MKIMAGE_DTCOPTS}" -F -k "${UBOOT_SIGN_KEYDIR}" -r "${B}/${KERNEL_OUTPUT_DIR}/fitImage-none" ${UBOOT_MKIMAGE_SIGN_ARGS}
        else
            ${UBOOT_MKIMAGE_SIGN} -F -k "${UBOOT_SIGN_KEYDIR}" -r "${B}/${KERNEL_OUTPUT_DIR}/fitImage-none" ${UBOOT_MKIMAGE_SIGN_ARGS}
        fi
    fi

    if [ "${INITRAMFS_IMAGE_BUNDLE}" != "1" ]; then
        ln -sf fitImage-none "${B}/${KERNEL_OUTPUT_DIR}/fitImage"
    fi
}

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
