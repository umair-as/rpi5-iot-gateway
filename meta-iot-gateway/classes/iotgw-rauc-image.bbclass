## RAUC image additions (always enabled in this distro)

# Explicitly set image formats (override meta-raspberrypi defaults)
# - tar.bz2: rootfs archive for backup/inspection
# - ext4: needed for RAUC bundles
# - wic.bz2: compressed disk image for flashing (best compression)
# - wic.bmap: block map for fast flashing with bmaptool
IMAGE_FSTYPES = "tar.bz2 ext4 wic.bz2 wic.bmap"

# Use strong assignment to override meta-raspberrypi's default WKS_FILE
WKS_FILE = "iot-gw-rauc-16g.wks.in"

# Packages required for RAUC flow
IMAGE_INSTALL += " \
    rauc \
    virtual-rauc-conf \
    overlayfs-setup \
    iotgw-bootfiles-updater \
    rauc-grow-data-part \
"

# Read-only rootfs pairs well with slot updates
IMAGE_FEATURES += " read-only-rootfs"

# Ensure data partition mount point and home base exist
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rauc_create_data_mount; iotgw_rauc_create_home_dirs;"
ROOTFS_POSTPROCESS_COMMAND += " iotgw_stage_bootfiles;"

iotgw_rauc_create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
}

iotgw_rauc_create_home_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/home
    if [ -d ${IMAGE_ROOTFS}/home/devel ]; then
        chown -R 1000:1000 ${IMAGE_ROOTFS}/home/devel
    fi
}

# Stage current boot files into rootfs so we can update /boot via service or bundle hooks
iotgw_stage_bootfiles() {
    install -d ${IMAGE_ROOTFS}/usr/share/iotgw/bootfiles
    for f in boot.scr u-boot.bin splash.bmp; do
        if [ -f ${DEPLOY_DIR_IMAGE}/$f ]; then
            install -m 0644 ${DEPLOY_DIR_IMAGE}/$f ${IMAGE_ROOTFS}/usr/share/iotgw/bootfiles/$f
        fi
    done
}

# Desktop profile hook (Wayland/Weston minimal stack when requested)
IMAGE_INSTALL:append:desktop = " ${IOTGW_DESKTOP_PACKAGES}"
