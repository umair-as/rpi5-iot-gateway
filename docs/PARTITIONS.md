# Partition Layouts

This document describes the disk partition layouts used for RAUC A/B OTA updates.

## Overview

The IoT Gateway OS uses an **A/B partition layout** for RAUC rootfs slot updates:
- Two root filesystem slots (A and B)
- Shared boot partition (kernel, DTBs, U-Boot)
- Persistent data partition

**WKS Files Location:** `meta-iot-gateway/wic/`

---

## Default Layout

This project defaults to a single production layout:

- `WKS_FILE = "iot-gw-rauc-128g.wks.in"`

The `/data` partition starts at a base size and is expanded to fill remaining
space on first boot by `rauc-grow-data-partition`.

| # | Device | Label | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | U-Boot, kernel, DTBs (shared) |
| 2 | `/dev/mmcblk0p2` | `ubootenv` | 16M | vfat (FAT32) | `/uboot-env` | Dedicated U-Boot environment store |
| 3 | `/dev/mmcblk0p3` | `rootA` | 16G | ext4 | `/` | Root filesystem Slot A |
| 4 | `/dev/mmcblk0p4` | `rootB` | 16G | ext4 | - | Root filesystem Slot B |
| 5 | `/dev/mmcblk0p5` | `data` | 84G | ext4 | `/data` | Persistent user data |

**Remaining Space:** ~20GB reserved for auto-grow
**After First Boot:** `/data` expands to fill remaining free space

Optional variants:
- `iot-gw-rauc-16g.wks.in`
- `iot-gw-rauc-32g.wks.in`
- `iot-gw-rauc-64g.wks.in`

Legacy template note:
- `iot-gw-rauc.wks.in` exists for generic/bring-up use and is not the default production layout in this project.

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

**RAUC Updates:** This partition is updated by RAUC bundle post-install hooks using the configured bootfiles archive (`bootfiles.tar.gz` or `bootfiles-fit.tar.gz` depending on bundle type).

---

### Partition 3 & 4: Root A/B (`rootA`, `rootB`)

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

### Partition 5: Data (`data`)

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
- `iot-gw-rauc-16g.wks.in`
- `iot-gw-rauc-32g.wks.in`
- `iot-gw-rauc-64g.wks.in`
- `iot-gw-rauc-128g.wks.in` (default)
- `iot-gw-rauc.wks.in` (legacy/generic template)

### Default Behavior

If `WKS_FILE` is not set, the 128GB layout is used automatically.

## Data Partition Auto-resize

On first boot, the `rauc-grow-data-partition` service automatically expands the `/data` partition to use all available unallocated space.

**Systemd Unit:** `rauc-grow-data-partition.service`

**Script:** `/usr/sbin/grow-data-partition.sh`

**Behavior:**
1. Detect `/data` partition (prefer `/dev/disk/by-rauc-slot/data`, fallback to by-label/lsblk)
2. Expand partition to fill disk
3. Resize ext4 filesystem
4. Write stamp file `/boot/.rauc-grow-done`
5. On subsequent boots, service is skipped via `ConditionPathExists=!/boot/.rauc-grow-done`

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
# Partition 3: rootA
part / --source rootfs --rootfs-dir=${IMAGE_ROOTFS} --ondisk mmcblk0 --fstype=ext4 --label rootA --align 4096 --fixed-size 4G --use-uuid

# Partition 4: rootB
part --ondisk mmcblk0 --fstype=ext4 --label rootB --align 4096 --fixed-size 4G --use-uuid

# Partition 5: data
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
