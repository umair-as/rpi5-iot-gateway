# ── Image-wide kernel module signature gate ──────────────────────────────────
# Every kernel module in the image must carry a signature trailer. The kernel
# runs CONFIG_MODULE_SIG_FORCE=y, so an unsigned .ko is not a build failure but
# a module that silently fails to load on the target. iotgw-kernel-module-
# signing checks each out-of-tree recipe it is inherited by; this checks the
# assembled rootfs, whatever recipe a module came from.
#
# With a persistent module-signing key (IOTGW_MODULE_SIG_KEY_FILE, see
# iotgw-kernel-module-sig-key.bbclass) each signature must also name that key:
# the signer serial (modinfo sig_key) equals the key certificate's serial. The
# signature itself is verified by the kernel at load. Without the variable the
# kernel signs with a key it generates at build time; only the trailers are
# checked then, with a warning.
#
# Verifies only. Kbuild (CONFIG_MODULE_SIG_ALL during modules_install) is the
# one signing authority; see iotgw-kernel-module-signing.bbclass.

IOTGW_MODULE_SIG_KEY_FILE ?= ""

ROOTFS_POSTPROCESS_COMMAND += "iotgw_check_modules_signed;"
do_rootfs[depends] += "kmod-native:do_populate_sysroot openssl-native:do_populate_sysroot"
do_rootfs[vardeps] += "IOTGW_MODULE_SIG_KEY_FILE"
do_rootfs[file-checksums] += "${@'%s:True' % d.getVar('IOTGW_MODULE_SIG_KEY_FILE') if d.getVar('IOTGW_MODULE_SIG_KEY_FILE') else ''}"

iotgw_check_modules_signed() {
    if [ ! -d ${IMAGE_ROOTFS}/lib/modules ]; then
        bbnote "module signature gate: no /lib/modules in the image; nothing to verify"
        return
    fi

    # No $(( )) here: BitBake's shell parser rejects arithmetic expansion.
    kos=$(find ${IMAGE_ROOTFS}/lib/modules -type f \( -name '*.ko' -o -name '*.ko.gz' \
               -o -name '*.ko.xz' -o -name '*.ko.zst' \) | sort)
    if [ -z "$kos" ]; then
        bbfatal "module signature gate: /lib/modules exists but holds no modules; either kernel-modules did not land in the image or they are packaged under a name this gate does not match"
    fi

    want=""
    if [ -n "${IOTGW_MODULE_SIG_KEY_FILE}" ]; then
        want=$(openssl x509 -in "${IOTGW_MODULE_SIG_KEY_FILE}" -noout -serial \
                 | sed 's/^serial=//; s/^0*//' | tr 'a-f' 'A-F')
        [ -n "$want" ] || bbfatal "module signature gate: cannot read the certificate serial from ${IOTGW_MODULE_SIG_KEY_FILE}"
    else
        bbwarn "module signature gate: IOTGW_MODULE_SIG_KEY_FILE is unset, so modules are signed by a key the kernel generated at build time; checking signature trailers only"
    fi

    tmpko=${WORKDIR}/iotgw-modsig-check.ko
    unsigned=""
    wrongkey=""
    for ko in $kos; do
        case "$ko" in
            *.ko.gz)  gzip -dc "$ko" > "$tmpko"; f="$tmpko" ;;
            *.ko.xz)  xz -dc "$ko" > "$tmpko"; f="$tmpko" ;;
            *.ko.zst) zstd -qdc "$ko" > "$tmpko"; f="$tmpko" ;;
            *)        f="$ko" ;;
        esac
        # A signed module ends with exactly this trailer; compare at the exact
        # offset, as iotgw-kernel-module-signing does.
        if [ "$(tail -c 28 "$f" | tr -d '\n\000')" != "~Module signature appended~" ]; then
            unsigned="$unsigned ${ko#${IMAGE_ROOTFS}}"
            continue
        fi
        if [ -n "$want" ]; then
            got=$(modinfo -F sig_key "$f" | tr -d ':' | sed 's/^0*//' | tr 'a-f' 'A-F')
            if [ "$got" != "$want" ]; then
                wrongkey="$wrongkey ${ko#${IMAGE_ROOTFS}}(sig_key=${got:-none})"
            fi
        fi
    done
    rm -f "$tmpko"

    if [ -n "$unsigned" ]; then
        bbfatal "module signature gate: unsigned kernel modules in the image; CONFIG_MODULE_SIG_FORCE rejects them at load:$unsigned"
    fi
    if [ -n "$wrongkey" ]; then
        bbfatal "module signature gate: kernel modules not signed by the module signing key (serial $want); CONFIG_MODULE_SIG_FORCE rejects them at load:$wrongkey"
    fi
    bbnote "module signature gate: $(echo $kos | wc -w) module(s) signed${want:+ by key serial $want}"
}
