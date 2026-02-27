LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

# Ensure the inputs are present in DEPLOY_DIR_IMAGE before we pack them (if available)
# Also pull in kernel deploy artifacts
DEPENDS += " u-boot rpi-u-boot-scr iotgw-bootlogo virtual/kernel rpi-bootfiles"

S = "${WORKDIR}"

IOTGW_BOOTFILES_ARCHIVE_NAME ?= "bootfiles.tar.gz"
IOTGW_BOOTFILES_STAGE_FILES ?= "boot.scr u-boot.bin config.txt cmdline.txt splash.bmp Image kernel_2712.img"
IOTGW_KERNEL_CONSOLE ?= "ttyAMA10,115200"

do_deploy() {
    install -d ${DEPLOYDIR}
    workdir=${WORKDIR}/bootfiles-stage
    rm -rf "$workdir"
    mkdir -p "$workdir"

    copy_first_existing() {
        dst="$1"
        shift
        for src in "$@"; do
            if [ -n "$src" ] && [ -e "$src" ]; then
                cp -L "$src" "$workdir/$dst" 2>/dev/null || cp -a "$src" "$workdir/$dst"
                return 0
            fi
        done
        return 1
    }

    require_staged_file() {
        f="$1"
        if [ ! -f "$workdir/$f" ]; then
            bbfatal "Required boot artifact '$f' was not staged into ${WORKDIR}/bootfiles-stage"
        fi
    }

    # Stage from DEPLOY_DIR_IMAGE if present
    cd ${DEPLOY_DIR_IMAGE}
    bootfiles_cfg_src=""
    bootfiles_cmd_src=""
    if [ -n "${BOOTFILES_DIR_NAME}" ]; then
        bootfiles_cfg_src="${BOOTFILES_DIR_NAME}/config.txt"
        bootfiles_cmd_src="${BOOTFILES_DIR_NAME}/cmdline.txt"
    fi

    # Stage critical artifacts using stable destination names with fallback candidates.
    # This avoids silent breakage if upstream deploy naming changes.
    copy_first_existing boot.scr \
        boot.scr || true

    copy_first_existing u-boot.bin \
        u-boot.bin \
        u-boot-${MACHINE}.bin || true

    copy_first_existing config.txt \
        config.txt \
        "$bootfiles_cfg_src" || true

    copy_first_existing cmdline.txt \
        cmdline.txt \
        "$bootfiles_cmd_src" || true

    # Stage remaining requested files (dereference symlinks where present).
    for f in ${IOTGW_BOOTFILES_STAGE_FILES}; do
        # Already handled via stable-name staging above.
        if [ "$f" = "boot.scr" ] || [ "$f" = "u-boot.bin" ] || [ "$f" = "config.txt" ] || [ "$f" = "cmdline.txt" ]; then
            continue
        fi
        if [ -e "$f" ]; then
            cp -L "$f" "$workdir/" 2>/dev/null || cp -a "$f" "$workdir/"
        fi
    done
    # Stage only machine DTBs selected by policy (RPI_KERNEL_DEVICETREE).
    # This avoids pulling versioned deploy artifacts (e.g. *-raspberrypi5-*.dtb).
    for dtb in ${RPI_KERNEL_DEVICETREE}; do
        dtb_base="${dtb##*/}"
        if [ -e "$dtb_base" ]; then
            cp -L "$dtb_base" "$workdir/" 2>/dev/null || cp -a "$dtb_base" "$workdir/"
        fi
    done

    # Keep kernel_2712.img as a compatibility alias where Image exists.
    if [ ! -f "$workdir/kernel_2712.img" ] && [ -f "$workdir/Image" ]; then
        cp -a "$workdir/Image" "$workdir/kernel_2712.img"
    fi
    # Include overlays: if a directory exists, copy it; otherwise collect *.dtbo and overlay_map*.dtb into overlays/
    if [ -d overlays ]; then
        mkdir -p "$workdir/overlays"
        cp -a overlays/* "$workdir/overlays/" 2>/dev/null || true
    else
        dtbocount=$(ls *.dtbo 2>/dev/null | wc -l)
        if [ "$dtbocount" -gt 0 ] || ls overlay_map*.dtb >/dev/null 2>&1; then
            mkdir -p "$workdir/overlays"
            cp -a *.dtbo "$workdir/overlays/" 2>/dev/null || true
            cp -a overlay_map*.dtb "$workdir/overlays/" 2>/dev/null || true
        fi
    fi

    cd "$workdir"
    # Write kernel.release based on modules archive if available (helps post-install validation)
    modules_tgz="${DEPLOY_DIR_IMAGE}/modules-${MACHINE}.tgz"
    if [ ! -f "$modules_tgz" ]; then
        # Backward-compatible fallback
        modules_tgz="${DEPLOY_DIR_IMAGE}/modules-raspberrypi5.tgz"
    fi
    if [ -f "$modules_tgz" ]; then
        rel=$(tar -tzf "$modules_tgz" | head -1 | sed -n 's#^\.?/*lib/modules/\([^/]*\)/.*#\1#p')
        if [ -n "$rel" ]; then
            echo "$rel" > "$workdir/kernel.release"
        fi
    fi

    # Validate required baseline artifacts.
    require_staged_file boot.scr
    require_staged_file u-boot.bin
    require_staged_file config.txt
    require_staged_file cmdline.txt

    # Normalize kernel console in shipped cmdline.txt.
    # Keep only one console= token and force the platform default.
    if [ -n "${IOTGW_KERNEL_CONSOLE}" ]; then
        cmdline_clean=$(sed -E 's/(^|[[:space:]])console=[^[:space:]]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' "$workdir/cmdline.txt")
        printf '%s console=%s\n' "$cmdline_clean" "${IOTGW_KERNEL_CONSOLE}" > "$workdir/cmdline.txt"
    fi

    # Validate kernel image presence for requested boot flow.
    case " ${IOTGW_BOOTFILES_STAGE_FILES} " in
        *" fitImage "*)
            require_staged_file fitImage
            ;;
        *)
            require_staged_file Image
            ;;
    esac

    # Staleness checks: fail if we staged different bootloader/script content than
    # the current deploy artifact symlinks.
    if [ -f "${DEPLOY_DIR_IMAGE}/u-boot.bin" ]; then
        staged_sha=$(sha256sum "$workdir/u-boot.bin" | awk '{print $1}')
        deploy_sha=$(sha256sum "${DEPLOY_DIR_IMAGE}/u-boot.bin" | awk '{print $1}')
        if [ "x$staged_sha" != "x$deploy_sha" ]; then
            bbfatal "Staged u-boot.bin hash mismatch (staged=$staged_sha deploy=$deploy_sha). Refusing stale bootfiles archive."
        fi
    fi
    if [ -f "${DEPLOY_DIR_IMAGE}/boot.scr" ]; then
        staged_sha=$(sha256sum "$workdir/boot.scr" | awk '{print $1}')
        deploy_sha=$(sha256sum "${DEPLOY_DIR_IMAGE}/boot.scr" | awk '{print $1}')
        if [ "x$staged_sha" != "x$deploy_sha" ]; then
            bbfatal "Staged boot.scr hash mismatch (staged=$staged_sha deploy=$deploy_sha). Refusing stale bootfiles archive."
        fi
    fi

    # Create the tar archive (empty tar if nothing staged)
    if [ -n "$(ls -A "$workdir" 2>/dev/null)" ]; then
        tar -czf ${DEPLOYDIR}/${IOTGW_BOOTFILES_ARCHIVE_NAME} .
    else
        tar -czf ${DEPLOYDIR}/${IOTGW_BOOTFILES_ARCHIVE_NAME} --files-from /dev/null || true
    fi
}

addtask deploy after do_install before do_build

# Ensure we run after all boot artifacts are deployed to DEPLOY_DIR_IMAGE.
# Without these task-level deploy dependencies, bootfiles archives can become
# stale (e.g. old u-boot.bin/boot.scr) even when newer artifacts exist.
do_deploy[depends] += " \
    virtual/kernel:do_deploy \
    rpi-bootfiles:do_deploy \
    u-boot:do_deploy \
    rpi-u-boot-scr:do_deploy \
    iotgw-bootlogo:do_deploy \
"

PACKAGE_ARCH = "${MACHINE_ARCH}"
