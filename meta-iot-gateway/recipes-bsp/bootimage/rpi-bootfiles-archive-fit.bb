SUMMARY = "Boot files archive (FIT variant) for RAUC post-install copy"
DESCRIPTION = "Packs bootloader and FIT kernel boot files into bootfiles.tar.gz for inclusion in RAUC bundles."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

# Ensure the inputs are present in DEPLOY_DIR_IMAGE before we pack them (if available)
# Also pull in kernel deploy artifacts
DEPENDS += " u-boot rpi-u-boot-scr iotgw-bootlogo virtual/kernel rpi-bootfiles"

S = "${WORKDIR}"

do_deploy() {
    install -d ${DEPLOYDIR}
    workdir=${WORKDIR}/bootfiles-stage
    rm -rf "$workdir"
    mkdir -p "$workdir"

    # Stage from DEPLOY_DIR_IMAGE if present
    cd ${DEPLOY_DIR_IMAGE}
    # Core boot files to attempt to stage (dereference symlinks where present)
    for f in boot.scr u-boot.bin config.txt cmdline.txt splash.bmp fitImage Image kernel_2712.img; do
        if [ -e "$f" ]; then
            # Create destination dir if needed and copy, dereferencing symlinks
            cp -L "$f" "$workdir/" 2>/dev/null || cp -a "$f" "$workdir/"
        fi
    done
    # Include all Raspberry Pi 5 family DTBs present in deploy dir.
    cp -a bcm2712-rpi-*.dtb "$workdir/" 2>/dev/null || true

    # Also pull firmware config files from BOOTFILES_DIR_NAME if present (meta-raspberrypi)
    if [ -n "${BOOTFILES_DIR_NAME}" ] && [ -d "${BOOTFILES_DIR_NAME}" ]; then
        for f in config.txt cmdline.txt; do
            if [ -e "${BOOTFILES_DIR_NAME}/$f" ]; then
                cp -a "${BOOTFILES_DIR_NAME}/$f" "$workdir/"
            fi
        done
    fi
    # For compatibility, keep kernel_2712.img as a copy of Image when available.
    # FIT flow should boot via U-Boot script using fitImage.
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
    # Create the tar archive (empty tar if nothing staged)
    if [ -n "$(ls -A "$workdir" 2>/dev/null)" ]; then
        tar -czf ${DEPLOYDIR}/bootfiles.tar.gz .
    else
        tar -czf ${DEPLOYDIR}/bootfiles.tar.gz --files-from /dev/null || true
    fi
}

addtask deploy after do_install before do_build

# Ensure we run after kernel deployed its artifacts to DEPLOY_DIR_IMAGE
do_deploy[depends] += "virtual/kernel:do_deploy rpi-bootfiles:do_deploy"

PACKAGE_ARCH = "${MACHINE_ARCH}"
