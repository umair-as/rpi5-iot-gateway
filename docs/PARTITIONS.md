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

```
 mmcblk0 (128 GiB SD card — default production layout)
 +----------+----------+------------------+------------------+-----------+
 |   boot   | ubootenv |      rootA       |      rootB       |   data    |
 |   (p1)   |   (p2)   |       (p3)       |       (p4)       |   (p5)   |
 |  256 MiB |  16 MiB  |     16 GiB       |     16 GiB       |  84 GiB  |
 |   vfat   |   vfat   |       ext4       |       ext4       |   ext4   |
 +----------+----------+------------------+------------------+-----------+
 | /boot    |/uboot-env|     / (active)   |    (standby)     |  /data   |
 | FIT,DTB, | fw_env   | read-only rootfs | RAUC update      |persistent|
 | config.txt| RAUC vars|                 | target           | storage  |
 +----------+----------+------------------+------------------+-----------+
                                      OTA swap ^---------------^
```

| # | Device | Label | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | FIT image, DTBs, config.txt (shared) |
| 2 | `/dev/mmcblk0p2` | `ubootenv` | 16M | vfat (FAT32) | `/uboot-env` | U-Boot env store (`fw_env.config` points here) |
| 3 | `/dev/mmcblk0p3` | `rootA` | 16G | ext4 | `/` | Root filesystem Slot A |
| 4 | `/dev/mmcblk0p4` | `rootB` | 16G | ext4 | - | Root filesystem Slot B |
| 5 | `/dev/mmcblk0p5` | `data` | 84G | ext4 | `/data` | Persistent user data |

**After First Boot:** `/data` expands to fill remaining free space via `rauc-grow-data-partition`.

### Size Variants

| WKS File | Card | boot | ubootenv | rootA/B | data | Notes |
|----------|------|------|----------|---------|------|-------|
| `iot-gw-rauc-16g.wks.in` | 16 GiB | 256M | 16M | 4G | 2G | Minimal/testing |
| `iot-gw-rauc-32g.wks.in` | 32 GiB | 256M | 16M | 6G | 12G | |
| `iot-gw-rauc-64g.wks.in` | 64 GiB | 256M | 16M | 8G | 36G | |
| `iot-gw-rauc-128g.wks.in` | 128 GiB | 256M | 16M | 16G | 84G | **Default** |
| `iot-gw-rauc.wks.in` | Generic | 512M | 16M | 8G | 10G | Bring-up/dev only |

---

## Partition Details

### Partition 1: Boot (`boot`)

**Format:** FAT32 (vfat)
**Size:** 256MB
**Mount:** `/boot`
**Read/Write:** Read-write (noatime,nodiratime)

**Contents:**
- U-Boot bootloader (`u-boot.bin`)
- FIT image (`fitImage` or per-slot `fitImage-a`/`fitImage-b`)
- Device tree blobs (`bcm2712-rpi-5-b.dtb`)
- Device tree overlays (`overlays/`)
- RPi firmware config (`config.txt`, `cmdline.txt`)

**RAUC Updates:** This partition is updated by RAUC bundle post-install hooks using the configured bootfiles archive (`bootfiles.tar.gz` or `bootfiles-fit.tar.gz` depending on bundle type).

---

### Partition 2: U-Boot Environment (`ubootenv`)

**Format:** FAT32 (vfat)
**Size:** 16MB
**Mount:** `/uboot-env`
**Read/Write:** Read-write

**Purpose:** Dedicated writable partition for U-Boot environment variables, kept separate from `/boot` so the boot partition can remain clean. `fw_env.config` points to device `0:2` (`ENV_FAT_DEVICE_AND_PART`).

**Key variables stored here:**
- `BOOT_ORDER` — RAUC slot priority (`A B` or `B A`)
- `BOOT_A_LEFT` / `BOOT_B_LEFT` — remaining boot attempts per slot
- `rauc_slot` — currently selected slot
- `bootcount` — boot attempt counter

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

See the **Size Variants** table above for all available options.

If `WKS_FILE` is not set, the 128 GiB layout is used automatically.

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
