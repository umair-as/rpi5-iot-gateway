# Project-owned FIT ITS extension for kernels that already inherit
# kernel-fitimage. This keeps multi-config policy logic out of recipe files.

IOTGW_FIT_CUSTOM_ITS ?= "0"
IOTGW_FIT_CUSTOM_ITS_TEMPLATE ?= "${WORKDIR}/iotgw-fit-single.its.in"
IOTGW_FIT_CUSTOM_ITS_DEFAULT_DTB ?= "broadcom/bcm2712-rpi-5-b.dtb"
IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH ?= ""
IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG ?= "gzip"
IOTGW_FIT_CUSTOM_ITS_REQUIRE_DISTINCT_KERNELS ?= "1"
IOTGW_FIT_CUSTOM_ITS_CONF_PRIMARY ?= "conf-primary"
IOTGW_FIT_CUSTOM_ITS_CONF_SECONDARY ?= "conf-recovery"
IOTGW_FIT_CUSTOM_ITS_DEFAULT_CONF ?= "${IOTGW_FIT_CUSTOM_ITS_CONF_PRIMARY}"

# Required when kernel-2 auto-generation uses lzo compression.
DEPENDS:append = "${@' lzop-native' if d.getVar('IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG') == 'lzo' else ''}"

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
    fdt_name="fdt-${dtb_name}"
    conf_primary="${IOTGW_FIT_CUSTOM_ITS_CONF_PRIMARY}"
    conf_secondary="${IOTGW_FIT_CUSTOM_ITS_CONF_SECONDARY}"
    default_conf="${IOTGW_FIT_CUSTOM_ITS_DEFAULT_CONF}"
    case "${default_conf}" in
        "${conf_primary}"|"${conf_secondary}") ;;
        *)
            bbfatal "IOTGW_FIT_CUSTOM_ITS_DEFAULT_CONF must be '${conf_primary}' or '${conf_secondary}', got '${default_conf}'"
            ;;
    esac

    kernel2_comp="${IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG}"
    case "${kernel2_comp}" in
        none|gzip|lzo) ;;
        *)
            bbfatal "unsupported IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG='${kernel2_comp}' (expected: none|gzip|lzo)"
            ;;
    esac

    kernel2_path="${IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH}"
    if [ -z "${kernel2_path}" ]; then
        bbnote "Auto-generating kernel-2 payload from local build artifacts (comp=${kernel2_comp})"
        kernel2_path="${B}/linux-k2.bin"
        rm -f "${kernel2_path}"

        if [ -e arch/${ARCH}/boot/compressed/vmlinux ]; then
            source_vmlinux="arch/${ARCH}/boot/compressed/vmlinux"
        elif [ -e arch/${ARCH}/boot/vmlinuz.bin ]; then
            cp -f arch/${ARCH}/boot/vmlinuz.bin "${kernel2_path}"
            source_vmlinux=""
            kernel2_comp="none"
        else
            source_vmlinux="vmlinux"
            if [ "${INITRAMFS_IMAGE_BUNDLE}" = "1" ] && [ -e vmlinux.initramfs ]; then
                source_vmlinux="vmlinux.initramfs"
            fi
        fi

        if [ -n "${source_vmlinux}" ]; then
            ${KERNEL_OBJCOPY} -O binary -R .note -R .comment -S "${source_vmlinux}" "${kernel2_path}"
            case "${kernel2_comp}" in
                none) ;;
                gzip)
                    gzip -9 -f "${kernel2_path}"
                    mv -f "${kernel2_path}.gz" "${kernel2_path}"
                    ;;
                lzo)
                    lzop -9 -f "${kernel2_path}"
                    mv -f "${kernel2_path}.lzo" "${kernel2_path}"
                    ;;
            esac
        fi
    fi
    [ -e "${kernel2_path}" ] || bbfatal "custom ITS mode could not find kernel-2 payload at '${kernel2_path}'"

    if [ "${IOTGW_FIT_CUSTOM_ITS_REQUIRE_DISTINCT_KERNELS}" = "1" ] && cmp -s "${kernel_path}" "${kernel2_path}"; then
        bbfatal "kernel-1 and kernel-2 payloads are identical; set IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH or adjust IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG"
    fi

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
        sed -i "/__IOTGW_CONF1_SIGNATURE__/r ${conf_sig_fragment}" "${its_path}"
        sed -i "/__IOTGW_CONF2_SIGNATURE__/r ${conf_sig_fragment}" "${its_path}"
    fi
    sed -i -e "s|__IOTGW_CONF1_SIGNATURE__||" -e "s|__IOTGW_CONF2_SIGNATURE__||" "${its_path}"

    sed -i \
        -e "s|@@FIT_DESC@@|${FIT_DESC}|g" \
        -e "s|@@FIT_ADDRESS_CELLS@@|${FIT_ADDRESS_CELLS}|g" \
        -e "s|@@UBOOT_ARCH@@|${UBOOT_ARCH}|g" \
        -e "s|@@UBOOT_MKIMAGE_KERNEL_TYPE@@|${UBOOT_MKIMAGE_KERNEL_TYPE}|g" \
        -e "s|@@UBOOT_LOADADDRESS@@|${UBOOT_LOADADDRESS}|g" \
        -e "s|@@UBOOT_ENTRYPOINT@@|${entrypoint}|g" \
        -e "s|@@FIT_HASH_ALG@@|${FIT_HASH_ALG}|g" \
        -e "s|@@KERNEL1_COMPRESSION@@|${linux_comp}|g" \
        -e "s|@@KERNEL2_COMPRESSION@@|${kernel2_comp}|g" \
        -e "s|@@CONF_PRIMARY@@|${conf_primary}|g" \
        -e "s|@@CONF_SECONDARY@@|${conf_secondary}|g" \
        -e "s|@@DEFAULT_CONF@@|${default_conf}|g" \
        -e "s|@@FDT_NAME@@|${fdt_name}|g" \
        -e "s|@@KERNEL1_PATH@@|${kernel_path}|g" \
        -e "s|@@KERNEL2_PATH@@|${kernel2_path}|g" \
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
