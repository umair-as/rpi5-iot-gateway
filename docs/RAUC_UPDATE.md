# RAUC Update Guide

This runbook covers installing and validating RAUC A/B bundle updates.

## Install Bundle

```bash
rauc install <bundle>.raucb
```

Track progress:

```bash
journalctl --no-pager -fu rauc
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

### What To Do If Misaligned

- Keep adaptive mode disabled (`IOTGW_RAUC_ADAPTIVE = "0"`) for current
  deployed layout.
- Re-enable adaptive mode only after reflashing with a 4 KiB-aligned partition
  table.
