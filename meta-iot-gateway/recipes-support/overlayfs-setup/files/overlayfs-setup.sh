#!/bin/sh
# Setup overlayfs mounts for read-only rootfs with RAUC
# This script creates writable overlays on /data for /etc, /var, /home, /root

set -e

DATA_PART="/data"
OVERLAY_BASE="${DATA_PART}/overlays"

# Directories to overlay (make writable on top of read-only rootfs)
OVERLAY_DIRS="/etc /var /home /root"

# Ensure /data is mounted
if ! mountpoint -q "${DATA_PART}"; then
    echo "ERROR: ${DATA_PART} is not mounted!"
    exit 1
fi

# Create overlay base directory structure
mkdir -p "${OVERLAY_BASE}"

for dir in ${OVERLAY_DIRS}; do
    dir_name=$(echo "${dir}" | sed 's|^/||' | tr '/' '_')
    upper="${OVERLAY_BASE}/${dir_name}/upper"
    work="${OVERLAY_BASE}/${dir_name}/work"

    # Create overlay directories
    mkdir -p "${upper}" "${work}"

    # Mount overlayfs
    echo "Setting up overlay for ${dir}..."
    mount -t overlay overlay \
        -o lowerdir="${dir}",upperdir="${upper}",workdir="${work}" \
        "${dir}"
done

echo "Overlayfs setup complete"
