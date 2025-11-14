#!/bin/sh
# Grow data partition to use remaining SD card space

set -e

# Data partition is typically /dev/mmcblk0p4
DATA_PART="/dev/mmcblk0p4"
DATA_DISK="/dev/mmcblk0"

# Check if already grown
if [ -f /var/lib/rauc-grow-done ]; then
    echo "Data partition already grown"
    exit 0
fi

echo "Growing data partition $DATA_PART..."

# Resize partition to maximum
parted -s "$DATA_DISK" resizepart 4 100%

# Resize filesystem
resize2fs "$DATA_PART"

echo "Data partition grown successfully"
