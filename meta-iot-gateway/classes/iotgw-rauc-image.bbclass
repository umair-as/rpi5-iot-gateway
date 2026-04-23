## RAUC image additions (always enabled in this distro)

# Explicitly set image formats (override meta-raspberrypi defaults)
# - tar.bz2: rootfs archive for backup/inspection
# - ext4: needed for RAUC bundles
# - wic.bz2: compressed disk image for flashing (best compression)
# - wic.bmap: block map for fast flashing with bmaptool
IMAGE_FSTYPES = "tar.bz2 ext4 wic.bz2 wic.bmap"

# Use strong assignment to override meta-raspberrypi's default WKS_FILE
WKS_FILE = "iot-gw-rauc-128g.wks.in"

# Keep stock /etc/fstab from base-files intact.
# WIC's imager-level fstab update appends mount lines globally and can create
# duplicates even when part-level --no-fstab-update is set in the .wks file.
WIC_CREATE_EXTRA_ARGS:append = " --no-fstab-update"

# Packages required for RAUC flow
IMAGE_INSTALL += " \
    rauc \
    rauc-service \
    virtual-rauc-conf \
    iotgw-rauc-install \
    iotgw-machine-id \
    boot-backup-prune \
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

# Validate generated WIC geometry for adaptive updates.
# This checks the final .direct artifact (not just WKS intent) and fails if
# rootA/rootB partition byte sizes are not 4KiB aligned.
python do_iotgw_validate_wic_alignment() {
    import glob
    import os

    if d.getVar("IOTGW_RAUC_ADAPTIVE") != "1":
        bb.note("WIC adaptive alignment check skipped (IOTGW_RAUC_ADAPTIVE != 1)")
        return

    alignment = 4096
    build_wic_dir = os.path.join(d.getVar("WORKDIR"), "build-wic")
    slot_sizes = {}
    source_desc = ""

    # Preferred path for current flow: split partition images .direct.pN.
    part3 = sorted(glob.glob(os.path.join(build_wic_dir, "*.direct.p3")), key=os.path.getmtime)
    part4 = sorted(glob.glob(os.path.join(build_wic_dir, "*.direct.p4")), key=os.path.getmtime)
    if part3 and part4:
        p3 = part3[-1]
        p4 = part4[-1]
        slot_sizes["rootA"] = os.path.getsize(p3)
        slot_sizes["rootB"] = os.path.getsize(p4)
        source_desc = "%s and %s" % (os.path.basename(p3), os.path.basename(p4))
    else:
        # Fallback for monolithic .direct image outputs.
        direct_images = sorted(
            glob.glob(os.path.join(build_wic_dir, "*.direct")),
            key=os.path.getmtime
        )
        if not direct_images:
            bb.fatal(
                "WIC adaptive alignment check: no .direct or .direct.p3/.direct.p4 artifacts found in %s"
                % build_wic_dir
            )

        direct_img = direct_images[-1]
        source_desc = os.path.basename(direct_img)
        out, _ = bb.process.run("sfdisk -d %s" % direct_img)

        import re
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("/dev/"):
                continue

            size_match = re.search(r"size=\s*([0-9]+)", line)
            name_match = re.search(r'name=\"([^\"]+)\"', line)
            if not size_match or not name_match:
                continue

            name = name_match.group(1)
            if name not in ("rootA", "rootB"):
                continue

            sectors = int(size_match.group(1))
            slot_sizes[name] = sectors * 512

    missing = [slot for slot in ("rootA", "rootB") if slot not in slot_sizes]
    if missing:
        bb.fatal(
            "WIC adaptive alignment check failed: missing root slot sizes from %s: %s"
            % (source_desc, ", ".join(missing))
        )

    for slot in ("rootA", "rootB"):
        size_bytes = slot_sizes[slot]
        if size_bytes % alignment != 0:
            bb.fatal(
                "WIC adaptive alignment check failed for %s in %s: size=%d bytes (mod %d = %d)"
                % (slot, direct_img, size_bytes, alignment, size_bytes % alignment)
            )

    bb.note(
        "WIC adaptive alignment check passed for %s: rootA=%d rootB=%d"
        % (source_desc, slot_sizes["rootA"], slot_sizes["rootB"])
    )
}

addtask iotgw_validate_wic_alignment after do_image_wic before do_image_complete
