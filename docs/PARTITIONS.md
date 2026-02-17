# Partition Layouts

This document describes the disk partition layouts used for RAUC A/B OTA updates.

## Overview

The IoT Gateway OS uses **A/B partition layout** for atomic OTA updates:
- Two root filesystem slots (A and B)
- Shared boot partition (kernel, DTBs, U-Boot)
- Persistent data partition

**WKS Files Location:** `meta-iot-gateway/wic/`

---

## Available Layouts

Three pre-configured layouts for different SD card sizes. The `/data` partition
starts at the base size shown below and is **expanded to fill remaining space**
on first boot by `rauc-grow-data-partition`.

| Card Size | WKS File | RootA/B Size | /data Base Size | Remaining (for auto-grow) |
|-----------|----------|--------------|-----------------|---------------------------|
| **16GB** (default) | `iot-gw-rauc-16g.wks.in` | 3G / 3G | 2G | ~7GB |
| **32GB** | `iot-gw-rauc-32g.wks.in` | 6G / 6G | 12G | ~8GB |
| **64GB** | `iot-gw-rauc-64g.wks.in` | 8G / 8G | 36G | ~12GB |

---

## 16GB Layout (Default)

**Total Allocated (base):** ~8.3GB
**Target Card:** 16GB SD card
**File:** `iot-gw-rauc-16g.wks.in`

| # | Device | Label | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | U-Boot, kernel, DTBs (shared) |
| 2 | `/dev/mmcblk0p2` | `rootA` | 3G | ext4 | `/` | Root filesystem Slot A |
| 3 | `/dev/mmcblk0p3` | `rootB` | 3G | ext4 | - | Root filesystem Slot B |
| 4 | `/dev/mmcblk0p4` | `data` | 2G | ext4 | `/data` | Persistent user data |

**Remaining Space:** ~7GB reserved for auto-grow
**After First Boot:** `/data` expands to fill remaining free space

**Use Case:** Compact IoT gateway, minimal storage requirements

---

## 32GB Layout

**Total Allocated (base):** ~24.3GB
**Target Card:** 32GB SD card
**File:** `iot-gw-rauc-32g.wks.in`

| # | Device | Label | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | U-Boot, kernel, DTBs (shared) |
| 2 | `/dev/mmcblk0p2` | `rootA` | 6G | ext4 | `/` | Root filesystem Slot A |
| 3 | `/dev/mmcblk0p3` | `rootB` | 6G | ext4 | - | Root filesystem Slot B |
| 4 | `/dev/mmcblk0p4` | `data` | 12G | ext4 | `/data` | Persistent user data |

**Remaining Space:** ~8GB reserved for auto-grow
**After First Boot:** `/data` expands to fill remaining free space

**Use Case:** Gateway with moderate storage needs, more data partition space

---

## 64GB Layout

**Total Allocated (base):** ~52.3GB
**Target Card:** 64GB SD card
**File:** `iot-gw-rauc-64g.wks.in`

| # | Device | Label | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | U-Boot, kernel, DTBs (shared) |
| 2 | `/dev/mmcblk0p2` | `rootA` | 8G | ext4 | `/` | Root filesystem Slot A |
| 3 | `/dev/mmcblk0p3` | `rootB` | 8G | ext4 | - | Root filesystem Slot B |
| 4 | `/dev/mmcblk0p4` | `data` | 36G | ext4 | `/data` | Persistent user data |

**Remaining Space:** ~12GB reserved for auto-grow
**After First Boot:** `/data` expands to fill remaining free space

**Use Case:** Gateway with heavy data logging, container images, media storage

---

## Partition Details

### Partition 1: Boot (`boot`)

**Format:** FAT32 (vfat)
**Size:** 256MB
**Mount:** `/boot`
**Read/Write:** Read-write (noatime,nodiratime)

**Contents:**
- U-Boot bootloader (`u-boot.bin`)
- Boot script (`boot.scr`)
- Linux kernel (`kernel_2712.img`, `Image`)
- Device tree blobs (`bcm2712-rpi-5-b.dtb`)
- Device tree overlays (`overlays/`)
- Boot splash image (`splash.bmp`, optional)
- First-boot provisioning (`iotgw/` directory)

**RAUC Updates:** This partition is updated by RAUC bundle post-install hooks (bootfiles.tar.gz).

---

### Partition 2 & 3: Root A/B (`rootA`, `rootB`)

**Format:** ext4
**Mount:** `/` (active slot only)
**Read/Write:** Read-only (RAUC requirement)

**Contents:**
- Full root filesystem
- `/usr`, `/bin`, `/lib`, `/etc`, etc.
- Applications and system services

**RAUC Behavior:**
- Active slot mounted at `/`
- Inactive slot remains unmounted
- OTA updates write to inactive slot
- Reboot switches slots via U-Boot

**⚠️ Read-only:** Root filesystem is mounted read-only for integrity. Use `/data` for persistent writes.

---

### Partition 4: Data (`data`)

**Format:** ext4
**Mount:** `/data`
**Read/Write:** Read-write
**Mount Options:** `noatime,nodiratime,commit=60`

**Purpose:**
- Persistent application data
- Logs (if not using journald volatile)
- Configuration files that survive updates
- Container volumes
- User data

**Note:** Journald persistent storage is under `/var/log/journal` on the overlay-backed `/var` (stored on `/data`).

**Survives OTA Updates:** This partition is not touched by RAUC updates.

**Auto-resize:** On first boot, `rauc-grow-data-partition` expands this partition to fill remaining space.

---

## Selecting a Layout

### At Build Time

Set `WKS_FILE` in your KAS overlay (`kas/local.yml`):

```yaml
local_conf_header:
  wks_file: |
    WKS_FILE = "iot-gw-rauc-32g.wks.in"
```

**Options:**
- `iot-gw-rauc-16g.wks.in` (default)
- `iot-gw-rauc-32g.wks.in`
- `iot-gw-rauc-64g.wks.in`

### Default Behavior

If `WKS_FILE` is not set, the 16GB layout is used automatically.

---

## Runtime Information

### Check Current Layout

```bash
# List partitions
lsblk

# Partition details
fdisk -l /dev/mmcblk0

# Filesystem info
df -h

# Mount points
mount | grep mmcblk0
```

**Example Output:**
```
/dev/mmcblk0p2 on / type ext4 (ro,relatime)
/dev/mmcblk0p1 on /boot type vfat (rw,noatime,nodiratime)
/dev/mmcblk0p4 on /data type ext4 (rw,noatime,nodiratime,commit=60)
```

### RAUC Slot Status

```bash
rauc status

# Output shows:
# - Active slot (A or B)
# - Inactive slot
# - Boot attempts remaining
```

---

## Data Partition Auto-resize

On first boot, the `rauc-grow-data-part` service automatically expands the `/data` partition to use all available unallocated space.

**Systemd Unit:** `rauc-grow-data-partition.service`

**Script:** `/usr/sbin/grow-data-partition.sh`

**Behavior:**
1. Detect `/data` partition (by label)
2. Expand partition to fill disk
3. Resize ext4 filesystem
4. Log results
5. Disable service (runs once)

**Logs:**
```bash
journalctl -u rauc-grow-data-partition
```

**Verify:**
```bash
df -h /data
```

---

## Custom Layouts

### Creating a Custom WKS File

1. Copy an existing layout:
```bash
cp meta-iot-gateway/wic/iot-gw-rauc-16g.wks.in \
   meta-iot-gateway/wic/iot-gw-rauc-custom.wks.in
```

2. Edit partition sizes:
```
# Partition 2: rootA
part / --source rootfs --rootfs-dir=${IMAGE_ROOTFS} --ondisk mmcblk0 --fstype=ext4 --label rootA --align 4096 --size 4G --use-uuid

# Partition 3: rootB
part --ondisk mmcblk0 --fstype=ext4 --label rootB --align 4096 --size 4G --use-uuid

# Partition 4: data
part --ondisk mmcblk0 --fstype=ext4 --label data --align 4096 --size 4G --use-uuid
```

3. Reference in KAS overlay:
```yaml
WKS_FILE = "iot-gw-rauc-custom.wks.in"
```

**⚠️ Important:** Root slots (A and B) must be the same size.

---

## Additional Resources

- [WIC Image Creator Documentation](https://docs.yoctoproject.org/ref-manual/kickstart.html)
- [RAUC Partition Layout](https://rauc.readthedocs.io/en/latest/integration.html#system-configuration)
- [ext4 Filesystem](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)
