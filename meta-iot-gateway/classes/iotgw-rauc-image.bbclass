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
    rauc-service \
    virtual-rauc-conf \
    rauc-healthcheck \
    overlayfs-setup \
    rauc-grow-data-part \
"

# Read-only rootfs pairs well with slot updates
IMAGE_FEATURES += " read-only-rootfs"

# Ensure data partition mount point and home base exist
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rauc_create_data_mount;"
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rauc_create_home_dirs;"

iotgw_rauc_create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
}

iotgw_rauc_create_home_dirs() {
    install -d -m 0755 ${IMAGE_ROOTFS}/home
    if [ -d ${IMAGE_ROOTFS}/home/devel ] && [ -r ${IMAGE_ROOTFS}/etc/passwd ]; then
        devel_uid=$(awk -F: '$1=="devel"{print $3}' ${IMAGE_ROOTFS}/etc/passwd)
        devel_gid=$(awk -F: '$1=="devel"{print $4}' ${IMAGE_ROOTFS}/etc/passwd)
        if [ -n "$devel_uid" ] && [ -n "$devel_gid" ]; then
            chown -R "${devel_uid}:${devel_gid}" ${IMAGE_ROOTFS}/home/devel || true
        fi
    fi
}

# Desktop profile hook (Wayland/Weston minimal stack when requested)
IMAGE_INSTALL:append:desktop = " ${IOTGW_DESKTOP_PACKAGES}"

## Note: bootfiles are updated via RAUC bundle hooks (bootfiles.tar.gz)
