# RAUC Update Guide

This runbook covers installing and validating RAUC A/B bundle updates.

## Mark-Good and Cleanup Flow

This image uses upstream RAUC mark-good semantics and a separate cleanup
oneshot for boot backup artifacts.

```bash
systemctl status rauc-mark-good.service
systemctl status boot-backup-prune.service
```

Current defaults:

- mark-good: `rauc-mark-good.service` (upstream RAUC)
- cleanup: `boot-backup-prune.service` runs after mark-good
- cleanup prunes old `/boot/*.bak*` artifacts and keeps recent backups

## Install Bundle

Manual install workflow (recommended):

```bash
iotgw-rauc-install <bundle>.raucb
```

Track progress:

```bash
journalctl --no-pager -fu rauc
```

Audit wrapper events (/boot rw window + restore):

```bash
journalctl --no-pager -t iotgw-rauc-install
```

## Check Slot State

```bash
rauc status
```

Expected:

- inactive slot is written during install
- target slot is marked active after install
- after reboot, system boots from the updated slot

## Adaptive Update (block-hash-index)

If enabled (`RAUC_SLOT_rootfs[adaptive] = "block-hash-index"`), RAUC requires
target rootfs slot sizes to be 4 KiB aligned.

If not aligned, RAUC logs an adaptive mode error and falls back to normal full
write, for example:

```text
Continuing after adaptive mode error: ... image/partition size (...) is not a multiple of 4096 bytes
```

### Verify Slot Alignment (target)

```bash
for p in /dev/mmcblk0p2 /dev/mmcblk0p3; do
  s=$(blockdev --getsize64 "$p")
  echo "$p size=$s mod4096=$((s%4096))"
done
```

Requirement:

- `mod4096=0` for all adaptive rootfs slots

## Troubleshooting

If install fails early with:

```text
Failed marking slot ... as bad/good: uboot backend: Failed to run fw_setenv: Child process exited with code 247
```

Check:

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /boot
fw_printenv
fw_setenv iotgw_test 2
```

Typical cause: `/boot` is mounted read-only while RAUC needs to update
`/boot/uboot.env`.

Use the wrapper command for manual installs:

```bash
iotgw-rauc-install <bundle>.raucb
```

If `rauc-mark-good.service` unexpectedly appears masked after update, check for
stale overlay masks in `/data/overlays/etc/upper/systemd/system/`.

### What To Do If Misaligned

- Keep adaptive mode disabled (`IOTGW_RAUC_ADAPTIVE = "0"`) for current
  deployed layout.
- Re-enable adaptive mode only after reflashing with a 4 KiB-aligned partition
  table.
