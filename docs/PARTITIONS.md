# Partition Layouts

This document describes the disk partition layouts used for RAUC A/B OTA updates.

## Overview

The IoT Gateway OS uses an **A/B partition layout** for RAUC rootfs slot updates:
- Two root filesystem slots (A and B)
- Shared boot partition (kernel, DTBs, U-Boot)
- Persistent data partition

**WKS Files Location:** `meta-iot-gateway/files/wic/`

---

## Default Layout

This project defaults to a single production layout:

- `WKS_FILE = "iot-gw-rauc-128g.wks.in"`

The `/data` partition starts at a base size and is expanded to fill remaining
space on first boot by the pre-init (`iotgw-preinit`).

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

| # | Device | Label / GPT name | Size | Type | Mount | Purpose |
|---|--------|-------|------|------|-------|---------|
| 1 | `/dev/mmcblk0p1` | `boot` | 256M | vfat (FAT32) | `/boot` | Per-slot signed FITs (`fitImage-a` / `fitImage-b`), U-Boot, firmware, config.txt (shared) |
| 2 | `/dev/mmcblk0p2` | `ubootenv` | 16M | vfat (FAT32) | `/uboot-env` | U-Boot env store (`fw_env.config` points here) |
| 3 | `/dev/mmcblk0p3` | `rootA` (GPT name; no fs label) | 16G | ext4 + dm-verity hash tree | `/` via `/dev/dm-0` | Root filesystem Slot A |
| 4 | `/dev/mmcblk0p4` | `rootB` (GPT name; no fs label) | 16G | ext4 + dm-verity hash tree | - | Root filesystem Slot B |
| 5 | `/dev/mmcblk0p5` | `data` | 84G | ext4 | `/data` | Persistent user data |

**After First Boot:** `/data` expands to fill remaining free space (pre-init, see below).

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
**Read/Write:** Read-write (`nodev,nosuid,noexec,noatime,nodiratime`)

**Contents:**
- U-Boot bootloader (`u-boot.bin`)
- Per-slot signed FITs `fitImage-a` / `fitImage-b` (kernel + DTB carrying the slot's dm-verity table)
- Device tree blob for the firmware (`bcm2712-rpi-5-b.dtb`)
- RPi firmware config (`config.txt`, `cmdline.txt`)

**Updates:** A RAUC install writes only the target slot's FIT (`fitImage-a` or `-b`), from the bundle (`bundle-hooks-fit.sh`). The shared files (U-Boot as `kernel_2712.img`, `config.txt` and the DTB that holds U-Boot's FIT trust anchor) are single-copy, so no slot switch can roll them back; they change only through `iotgw-rpi-bootfiles-update`, run by an operator. That tool refuses a DTB that does not trust both installed slot FITs, snapshots the current files to `/data/rpi-boot/backup/` before writing and has `--restore`. See [RAUC Update](RAUC_UPDATE.md#shared-boot-files).

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
**Read/Write:** Read-only, mounted through dm-verity (`/dev/dm-0`)

**Contents:**
- Full root filesystem
- `/usr`, `/bin`, `/lib`, `/etc`, etc.
- Applications and system services

Each slot holds the same ext4 image with its dm-verity hash tree appended. The
root hash is on the kernel command line inside the slot's signed FIT, so a
modified slot fails to assemble and the boot counter falls back to the other
slot.

**RAUC Behavior:**
- Active slot mounted at `/`
- Inactive slot remains unmounted
- OTA updates write to inactive slot
- Reboot switches slots via U-Boot

**⚠️ Read-only:** Use `/data` for persistent writes.

---

### Partition 5: Data (`data`)

**Format:** ext4
**Mount:** `/data`
**Read/Write:** Read-write
**Mount Options:** `noatime,nodiratime,commit=60`

**Purpose:**
- Persistent application data and user data
- Persistent runtime state re-homed off the read-only rootfs (journald and audit
  logs, SSH host keys, TPM2 PKCS#11 token DB, and more)
- `/home` (`/data/home`, bound over `/home` before systemd starts)
- Rootless container storage (`/data/home/iotgw-ctr/.local/share/containers`, through the `/home` bind)

`/data` is mounted by `iotgw-preinit` before systemd starts, located as the GPT
partition named `data` on the disk that holds the verity root, after a
time-limited `e2fsck -p`. If it cannot be mounted the device boots in a
degraded recovery mode instead of stopping. Nothing on `/data` is an overlay
layer: `/etc` and `/root` come from the slot with a tmpfs upper layer and are
reset at every boot.

**Note:** `/var` is **not** overlay-backed. Journald and audit logs persist on
`/data` (`/data/log/{journal,audit}`) via dedicated bind mounts, not an overlay.
The full writable/persistent-state layout — what is volatile, what persists, and
what survives A/B updates — is documented in
[Persistent State Architecture](PERSISTENT_STATE.md).

**Survives OTA Updates:** This partition is not touched by RAUC updates.

**Auto-resize:** On first boot, the pre-init expands this partition to fill remaining space.

---

## Selecting a Layout

### At Build Time

`iotgw-rauc-image.bbclass` assigns `WKS_FILE` with a strong `=` that is parsed
after `local.conf`, so a plain `WKS_FILE =` in `kas/local.yml` has no effect.
Use a per-image override in your KAS overlay (`kas/local.yml`):

```yaml
local_conf_header:
  wks_file: |
    WKS_FILE:pn-iot-gw-image-dev = "iot-gw-rauc-32g.wks.in"
```

See the **Size Variants** table above for all available options.

If `WKS_FILE` is not set, the 128 GiB layout is used automatically.

## Data Partition Auto-resize

The pre-init (`/usr/sbin/iotgw-preinit`, the kernel's `init=`) expands `/data` to
use all unallocated space at the end of the card. It does this before it mounts
`/data`: a partition cannot be resized while it is mounted, and the pre-init is
the only point in the boot where nothing has mounted it yet.

**Behavior** (every boot; decided from the partition table, no stamp file):
1. Find the partition named `data` on the disk that carries the verity root.
2. If more than 1 MiB lies between its end and the backup GPT: move the backup
   GPT to the end of the card (`sgdisk -e`) and extend the partition to 100%
   (`parted resizepart`).
3. `e2fsck -p`, mount.
4. If the filesystem is smaller than its partition: grow it online
   (`resize2fs` on the mounted ext4).

A boot with nothing to grow does nothing; one interrupted half way finishes on
the next boot. A growth failure is logged in `/run/iotgw/preinit.log` and the
boot continues on the smaller `/data`; it never marks the boot degraded.
Host tests: `scripts/preinit/tests/test_data_grow.py` (`make test SUITE=boot`).

---

## Custom Layouts

### Creating a Custom WKS File

1. Copy an existing layout:
```bash
cp meta-iot-gateway/files/wic/iot-gw-rauc-16g.wks.in \
   meta-iot-gateway/files/wic/iot-gw-rauc-custom.wks.in
```

2. Edit partition sizes:
```
# Partition 3: rootA
part / ${IOTGW_WKS_ROOT_A_ARGS} --ondisk mmcblk0 --part-name rootA --align 4096 --fixed-size 4G --uuid <fixed-uuid-a>

# Partition 4: rootB
part   ${IOTGW_WKS_ROOT_B_ARGS} --ondisk mmcblk0 --part-name rootB --align 4096 --fixed-size 4G --uuid <fixed-uuid-b>

# Partition 5: data
part /data --ondisk mmcblk0 --fstype=ext4 --label data --align 4096 --size 4G --fsoptions "defaults" --no-fstab-update
```

Root slots must not carry `--label`: the rawcopy plugin would relabel the
copied ext4 image after its hash tree was computed and invalidate the root
hash. RAUC selects slots by the GPT name from `--part-name`.

3. Reference it in the KAS overlay with a per-image override (see
   [At Build Time](#at-build-time)):
```yaml
WKS_FILE:pn-iot-gw-image-dev = "iot-gw-rauc-custom.wks.in"
```

**⚠️ Important:** Root slots (A and B) must be the same size and at least the
size of the `.ext4.verity` image. Keep the fixed `--uuid` values (U-Boot reads
the live PARTUUID).

---

## Additional Resources

- [WIC Image Creator Documentation](https://docs.yoctoproject.org/ref-manual/kickstart.html)
- [RAUC Partition Layout](https://rauc.readthedocs.io/en/latest/integration.html#system-configuration)
- [ext4 Filesystem](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)
