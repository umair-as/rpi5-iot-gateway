require recipes-kernel/linux/linux-iotgw-mainline-common.inc

# CVE exclusions
include recipes-kernel/linux/cve-exclusion.inc
include recipes-kernel/linux/cve-exclusion_6.18.inc

LINUX_VERSION ?= "6.18.37"
KERNEL_VERSION_SANITY_SKIP = "1"
PV = "${LINUX_VERSION}+git${SRCPV}"

BRANCH ?= "linux-6.18.y"
KMETA = "kernel-meta"

# SRCREV_machine / SRCREV_meta / SRCREV_FORMAT live in
# linux-iotgw-mainline-common.inc so all three kernel providers stay in lockstep.

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;name=machine;branch=${BRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=yocto-6.6;destsuffix=${KMETA};protocol=https \
"

# Wrynose split-FIT model: the kernel recipe no longer assembles the FIT
# itself (kernel-fitimage.bbclass / do_assemble_fitimage were removed in
# OE-Core wrynose). It builds a plain arm64 Image and PUBLISHES the FIT input
# artifacts (linux.bin + linux_comp) via kernel-fit-extra-artifacts. The
# separate linux-iotgw-fit recipe (inherit kernel-fit-image) consumes those to
# assemble and sign the FIT. See docs/FIT_BOOT_SIGNING.md.
KERNEL_IMAGETYPE = "Image"
KERNEL_CLASSES:append = " kernel-fit-extra-artifacts"

# FIT DTB trust roots — see kas/local.yml.example fit_dtb_*_trust blocks for
# the rotation pattern. The file-key gate defaults on so a developer without a
# YubiKey or SoftHSM can still build normally. The YK and SoftHSM gates default
# off; flip them on in kas/local.yml only when the corresponding key material
# is present. The SoftHSM gate is dev-only — do not enable it on production.
#
# These control-DTB pubkeys let U-Boot's control FDT enforce FIT config
# signatures at runtime; they are injected into the deployed board DTBs here
# (this recipe owns the DTBs), independent of the FIT signing done by the
# linux-iotgw-fit recipe with the same file key.
IOTGW_FIT_TRUST_FILE_KEY    ?= "1"
IOTGW_FIT_TRUST_YK_KEY      ?= "0"
IOTGW_FIT_YK_KEYDIR         ?= ""
IOTGW_FIT_YK_KEYNAME        ?= "iotgw-fit-yk-2026"
IOTGW_FIT_TRUST_SOFTHSM_KEY ?= "0"
IOTGW_FIT_SOFTHSM_KEYDIR    ?= ""
IOTGW_FIT_SOFTHSM_KEYNAME   ?= "iotgw-fit-softhsm-dev"

# fdt_add_pubkey lands in the native sysroot via meta-iot-gateway's
# u-boot-tools bbappend. Used uniformly for all three trust roots (in the
# split-FIT model the fitImage no longer lives in this recipe, so the former
# `mkimage -F -K <dtb> -r <fit>` file-key path is replaced by fdt_add_pubkey,
# which writes the same /signature/key-<name> node from the signing cert).
#
# Dropping kernel-fitimage (split-FIT re-arch) also dropped its implicit
# u-boot-tools-native DEPENDS, so declare it explicitly — do_deploy:append
# below invokes fdt_add_pubkey from the native sysroot.
DEPENDS += "u-boot-tools-native"
UBOOT_FDT_ADD_PUBKEY ?= "${STAGING_BINDIR_NATIVE}/fdt_add_pubkey"

# Raspberry Pi firmware passes a runtime-prepared DTB to U-Boot. Inject FIT
# public keys into the deployed firmware DTBs so U-Boot's control FDT exposes
# /signature and enforces FIT config signatures on target.
#
# Up to three trust roots can be injected side-by-side via the
# IOTGW_FIT_TRUST_* gates: file key (build-time signing), YubiKey-resident
# pubkey (production HSM signing), and SoftHSM pubkey (dev-only).
# /signature/required-mode is set to "any" only when more than one root is
# enabled. All gates off with UBOOT_SIGN_ENABLE=1 is fatal.
do_deploy:append() {
    if [ "${UBOOT_SIGN_ENABLE}" != "1" ]; then
        bbnote "FIT DTB key injection skipped: UBOOT_SIGN_ENABLE=${UBOOT_SIGN_ENABLE}"
        return
    fi

    trust_file="${IOTGW_FIT_TRUST_FILE_KEY}"
    trust_yk="${IOTGW_FIT_TRUST_YK_KEY}"
    trust_softhsm="${IOTGW_FIT_TRUST_SOFTHSM_KEY}"

    if [ "${trust_file}" != "1" ] && [ "${trust_yk}" != "1" ] && [ "${trust_softhsm}" != "1" ]; then
        bbfatal "FIT DTB trust misconfigured: all three of IOTGW_FIT_TRUST_FILE_KEY / IOTGW_FIT_TRUST_YK_KEY / IOTGW_FIT_TRUST_SOFTHSM_KEY are off with UBOOT_SIGN_ENABLE=1 — would brick the device. Enable at least one trust root."
    fi

    if [ "${trust_file}" = "1" ]; then
        if [ -z "${UBOOT_SIGN_KEYDIR}" ] || [ ! -d "${UBOOT_SIGN_KEYDIR}" ]; then
            bbwarn "FIT DTB file-key injection skipped: missing UBOOT_SIGN_KEYDIR='${UBOOT_SIGN_KEYDIR}'"
            trust_file="0"
        elif [ ! -f "${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt" ]; then
            bbwarn "FIT DTB file-key injection skipped: missing ${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt"
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
    fi

    if [ "${trust_softhsm}" = "1" ]; then
        if [ -z "${IOTGW_FIT_SOFTHSM_KEYDIR}" ] || [ ! -d "${IOTGW_FIT_SOFTHSM_KEYDIR}" ]; then
            bbfatal "FIT DTB SoftHSM-key injection requires IOTGW_FIT_SOFTHSM_KEYDIR pointing to a directory holding ${IOTGW_FIT_SOFTHSM_KEYNAME}.crt (got: '${IOTGW_FIT_SOFTHSM_KEYDIR}'). SoftHSM trust is dev-only — see docs/FIT_BOOT_SIGNING.md."
        fi
        if [ ! -f "${IOTGW_FIT_SOFTHSM_KEYDIR}/${IOTGW_FIT_SOFTHSM_KEYNAME}.crt" ]; then
            bbfatal "FIT DTB SoftHSM-key injection requires public certificate at ${IOTGW_FIT_SOFTHSM_KEYDIR}/${IOTGW_FIT_SOFTHSM_KEYNAME}.crt — see docs/FIT_BOOT_SIGNING.md for the SoftHSM provisioning runbook."
        fi
    fi

    if [ "${trust_file}" != "1" ] && [ "${trust_yk}" != "1" ] && [ "${trust_softhsm}" != "1" ]; then
        bbfatal "FIT DTB trust resolved to zero roots after validation — refusing to deploy unsigned-trust DTBs with UBOOT_SIGN_ENABLE=1"
    fi

    if [ ! -x "${UBOOT_FDT_ADD_PUBKEY}" ]; then
        bbfatal "fdt_add_pubkey not found at '${UBOOT_FDT_ADD_PUBKEY}' — ensure u-boot-tools-native installs it (see meta-iot-gateway/recipes-bsp/u-boot/u-boot-tools_%.bbappend)"
    fi

    # Count enabled trust roots without shell arithmetic expansion
    # ($((…)) is unsupported by BitBake's shell parser).
    case "${trust_file}-${trust_yk}-${trust_softhsm}" in
        1-1-1) trust_count=3 ;;
        1-1-0|1-0-1|0-1-1) trust_count=2 ;;
        1-0-0|0-1-0|0-0-1) trust_count=1 ;;
        *) trust_count=0 ;;
    esac

    deploy_dir="${DEPLOYDIR}"
    if [ -n "${KERNEL_DEPLOYSUBDIR}" ]; then
        deploy_dir="${DEPLOYDIR}/${KERNEL_DEPLOYSUBDIR}"
    fi

    if [ -z "${RPI_KERNEL_DEVICETREE}" ]; then
        bbwarn "FIT DTB key injection skipped: RPI_KERNEL_DEVICETREE is empty"
        return
    fi

    bbnote "FIT DTB trust roots: file=${trust_file} yk=${trust_yk} softhsm=${trust_softhsm} count=${trust_count} algo=${FIT_HASH_ALG},${FIT_SIGN_ALG}"

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
            bbnote "Injecting file-key pubkey (${UBOOT_SIGN_KEYNAME}) into ${dtb_path}"
            ${UBOOT_FDT_ADD_PUBKEY} \
                -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
                -k "${UBOOT_SIGN_KEYDIR}" \
                -n "${UBOOT_SIGN_KEYNAME}" \
                -r conf \
                "${dtb_path}"
        fi

        if [ "${trust_yk}" = "1" ]; then
            bbnote "Injecting YK pubkey (${IOTGW_FIT_YK_KEYNAME}) into ${dtb_path}"
            ${UBOOT_FDT_ADD_PUBKEY} \
                -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
                -k "${IOTGW_FIT_YK_KEYDIR}" \
                -n "${IOTGW_FIT_YK_KEYNAME}" \
                -r conf \
                "${dtb_path}"
        fi

        if [ "${trust_softhsm}" = "1" ]; then
            bbnote "Injecting SoftHSM dev pubkey (${IOTGW_FIT_SOFTHSM_KEYNAME}) into ${dtb_path}"
            ${UBOOT_FDT_ADD_PUBKEY} \
                -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
                -k "${IOTGW_FIT_SOFTHSM_KEYDIR}" \
                -n "${IOTGW_FIT_SOFTHSM_KEYNAME}" \
                -r conf \
                "${dtb_path}"
        fi

        # required-mode = "any" lets a FIT signed by any one of multiple
        # required trust roots verify. Omitted for a single root, where
        # U-Boot's default semantics apply.
        if [ "${trust_count}" -gt 1 ]; then
            bbnote "Setting /signature/required-mode=any on ${dtb_path} (trust_count=${trust_count})"
            fdtput -t s "${dtb_path}" /signature required-mode any
        else
            bbnote "Single trust root (count=1) — leaving /signature/required-mode unset on ${dtb_path}"
        fi
    done
}
