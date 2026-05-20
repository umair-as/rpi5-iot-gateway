require recipes-kernel/linux/linux-iotgw-mainline-common.inc

LINUX_VERSION ?= "6.18+"
KERNEL_VERSION_SANITY_SKIP = "1"
PV = "${LINUX_VERSION}+git${SRCPV}"

BRANCH ?= "linux-6.18.y"
KMETA = "kernel-meta"

# SRCREV_machine / SRCREV_meta / SRCREV_FORMAT live in
# linux-iotgw-mainline-common.inc so all three kernel providers stay in lockstep.

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;name=machine;branch=${BRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.6;destsuffix=${KMETA};protocol=https \
    file://iotgw-fit-single.its.in \
"

# FIT image variant: compile normal arm64 Image payload and package as fitImage.
KERNEL_IMAGETYPE = "fitImage"
KERNEL_CLASSES = " kernel-fitimage "
inherit iotgw-fit-custom-its

# Strategy A (optional): feed kernel-2 from an independent recovery kernel
# build artifact instead of auto-generated kernel payload transformations.
IOTGW_FIT_STRATEGY_A_RECOVERY_KERNEL ?= "0"
IOTGW_FIT_RECOVERY_KERNEL_RECIPE ?= "linux-iotgw-mainline-recovery"
IOTGW_FIT_RECOVERY_KERNEL_PATH ?= "${DEPLOY_DIR_IMAGE}/linux-recovery.bin"

IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG ?= "none"

# FIT DTB trust roots — see kas/local.yml.example fit_dtb_yk_pubkey_trust
# block for the rotation pattern. Both gates default to a file-key-only
# transition image; flip IOTGW_FIT_TRUST_YK_KEY=1 in kas/local.yml to add
# the YubiKey public certificate as a second trust root.
IOTGW_FIT_TRUST_FILE_KEY ?= "1"
IOTGW_FIT_TRUST_YK_KEY   ?= "0"
IOTGW_FIT_YK_KEYDIR      ?= ""
IOTGW_FIT_YK_KEYNAME     ?= "iotgw-fit-yk-2026"

# fdt_add_pubkey lands in the native sysroot via meta-iot-gateway's
# u-boot-tools bbappend; mirrors the UBOOT_MKIMAGE_SIGN naming used by
# kernel-fitimage.bbclass.
UBOOT_FDT_ADD_PUBKEY ?= "${STAGING_BINDIR_NATIVE}/fdt_add_pubkey"

python () {
    if d.getVar("IOTGW_FIT_STRATEGY_A_RECOVERY_KERNEL") != "1":
        return
    recovery_recipe = d.getVar("IOTGW_FIT_RECOVERY_KERNEL_RECIPE")
    if not recovery_recipe:
        bb.fatal("IOTGW_FIT_RECOVERY_KERNEL_RECIPE is empty while Strategy A is enabled")
    if not d.getVar("IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH"):
        d.setVar("IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH", d.getVar("IOTGW_FIT_RECOVERY_KERNEL_PATH"))
    d.appendVarFlag("do_assemble_fitimage", "depends", " %s:do_deploy" % recovery_recipe)
}

# Raspberry Pi firmware passes a runtime-prepared DTB to U-Boot. Inject FIT
# public keys into deployed firmware DTBs so U-Boot control FDT can expose
# /signature and enforce FIT config signatures on target.
#
# Two trust roots can be injected side-by-side via the IOTGW_FIT_TRUST_*
# gates. When both are enabled, /signature/required-mode is set to "any"
# so a FIT signed by either root verifies — the rotation window mode.
# Setting both gates to 0 with UBOOT_SIGN_ENABLE=1 is fatal: a signed-FIT
# enforced device with no trust roots would brick on first boot.
do_deploy:append() {
    if [ "${UBOOT_SIGN_ENABLE}" != "1" ]; then
        bbnote "FIT DTB key injection skipped: UBOOT_SIGN_ENABLE=${UBOOT_SIGN_ENABLE}"
        return
    fi

    trust_file="${IOTGW_FIT_TRUST_FILE_KEY}"
    trust_yk="${IOTGW_FIT_TRUST_YK_KEY}"

    if [ "${trust_file}" != "1" ] && [ "${trust_yk}" != "1" ]; then
        bbfatal "FIT DTB trust misconfigured: IOTGW_FIT_TRUST_FILE_KEY=0 and IOTGW_FIT_TRUST_YK_KEY=0 with UBOOT_SIGN_ENABLE=1 would brick the device. Enable at least one trust root."
    fi

    if [ "${trust_file}" = "1" ]; then
        if [ -z "${UBOOT_SIGN_KEYDIR}" ] || [ ! -d "${UBOOT_SIGN_KEYDIR}" ]; then
            bbwarn "FIT DTB file-key injection skipped: missing UBOOT_SIGN_KEYDIR='${UBOOT_SIGN_KEYDIR}'"
            trust_file="0"
        fi
    fi

    if [ "${trust_yk}" = "1" ]; then
        if [ -z "${IOTGW_FIT_YK_KEYDIR}" ] || [ ! -d "${IOTGW_FIT_YK_KEYDIR}" ]; then
            bbfatal "FIT DTB YK-key injection requires IOTGW_FIT_YK_KEYDIR pointing to a directory holding ${IOTGW_FIT_YK_KEYNAME}.crt (got: '${IOTGW_FIT_YK_KEYDIR}')"
        fi
        if [ ! -f "${IOTGW_FIT_YK_KEYDIR}/${IOTGW_FIT_YK_KEYNAME}.crt" ]; then
            bbfatal "FIT DTB YK-key injection requires public certificate at ${IOTGW_FIT_YK_KEYDIR}/${IOTGW_FIT_YK_KEYNAME}.crt — export with: ykman piv certificates export 9a <path>"
        fi
        if [ ! -x "${UBOOT_FDT_ADD_PUBKEY}" ]; then
            bbfatal "fdt_add_pubkey not found at '${UBOOT_FDT_ADD_PUBKEY}' — ensure u-boot-tools-native installs it (see meta-iot-gateway/recipes-bsp/u-boot/u-boot-tools_%.bbappend)"
        fi
    fi

    if [ "${trust_file}" != "1" ] && [ "${trust_yk}" != "1" ]; then
        bbfatal "FIT DTB trust resolved to zero roots after validation — refusing to deploy unsigned-trust DTBs with UBOOT_SIGN_ENABLE=1"
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

    bbnote "FIT DTB trust roots: file=${trust_file} yk=${trust_yk} algo=${FIT_HASH_ALG},${FIT_SIGN_ALG}"

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

        if [ "${trust_file}" = "1" ]; then
            bbnote "Injecting file-key (${UBOOT_SIGN_KEYNAME}) into ${dtb_path}"
            ${UBOOT_MKIMAGE_SIGN} \
                ${@'-D "${UBOOT_MKIMAGE_DTCOPTS}"' if d.getVar('UBOOT_MKIMAGE_DTCOPTS') else ''} \
                -F -k "${UBOOT_SIGN_KEYDIR}" \
                -K "${dtb_path}" \
                -r "${fit_path}" \
                ${UBOOT_MKIMAGE_SIGN_ARGS}
        fi

        if [ "${trust_yk}" = "1" ]; then
            bbnote "Injecting YK pubkey (${IOTGW_FIT_YK_KEYNAME}) into ${dtb_path}"
            ${UBOOT_FDT_ADD_PUBKEY} \
                -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
                -k "${IOTGW_FIT_YK_KEYDIR}" \
                -n "${IOTGW_FIT_YK_KEYNAME}" \
                -r conf \
                "${dtb_path}"

            # required-mode = "any" lets a FIT signed by either trust
            # root verify. Without this, multiple required = "conf"
            # keys make U-Boot require ALL of them, rejecting any FIT
            # signed by only one root — the bricking case.
            bbnote "Setting /signature/required-mode=any on ${dtb_path}"
            fdtput -t s "${dtb_path}" /signature required-mode any
        fi
    done
}
