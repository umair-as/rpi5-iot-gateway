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

log() { echo "[overlayfs-setup] $*"; }

# Create overlay base directory structure
log "Initializing overlay base at ${OVERLAY_BASE}"
mkdir -p "${OVERLAY_BASE}"

for dir in ${OVERLAY_DIRS}; do
    dir_name=$(echo "${dir}" | sed 's|^/||' | tr '/' '_')
    upper="${OVERLAY_BASE}/${dir_name}/upper"
    work="${OVERLAY_BASE}/${dir_name}/work"

    # Create overlay directories
    mkdir -p "${upper}" "${work}"

    # If already mounted as overlay, ensure it is writable
    if mountpoint -q "${dir}" && mount | grep -q "on ${dir} type overlay"; then
        log "${dir} already mounted as overlay; remounting rw"
        if ! mount -o remount,rw "${dir}"; then
            log "WARN: remount failed for ${dir}, retrying with overlay type"
            if ! mount -t overlay overlay -o remount,rw "${dir}"; then
                log "WARN: remount still failed for ${dir}"
            fi
        fi
        continue
    fi

    # Mount overlayfs with extra safety on selected paths
    # Default options
    opts="lowerdir=${dir},upperdir=${upper},workdir=${work},rw"
    case "${dir}" in
        /home|/var)
            opts="${opts},nodev,nosuid"
            ;;
    esac
    log "Setting up overlay for ${dir}"
    if ! mount -t overlay overlay -o "${opts}" "${dir}"; then
        log "ERROR: failed to mount overlay for ${dir}"
        exit 1
    fi
done

# Ensure persistent journald storage exists after /var overlay is mounted.
if [ ! -d /var/log/journal ]; then
    log "Creating /var/log/journal for persistent journald storage"
fi
mkdir -p /var/log/journal
chown root:systemd-journal /var/log/journal
chmod 2755 /var/log/journal

log "Overlayfs setup complete"
