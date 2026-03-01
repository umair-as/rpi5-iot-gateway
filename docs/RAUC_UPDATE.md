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

HTTPS streaming install (manual, recommended for OTA server flow):

```bash
iotgw-rauc-install https://<ota-host>:8443/bundles/<bundle>.raucb
```

Behavior notes:

- default path: wrapper dispatches through `systemd-run` to execute from system
  manager context (recommended on hardened systems)
- fallback path: direct execution (`--direct` or `--no-systemd-run`) for debug
  only

Track progress:

```bash
journalctl --no-pager -fu rauc
```

Audit wrapper events (/boot rw window + restore):

```bash
journalctl --no-pager -t iotgw-rauc-install
```

### Streaming Preflight (mTLS)

Before remote installs, verify cert chain and manifest reachability:

```bash
openssl verify -CAfile /etc/ota/ca.crt /etc/ota/device.crt
curl --cert /etc/ota/device.crt \
     --key /etc/ota/device.key \
     --cacert /etc/ota/ca.crt \
     -fsS https://<ota-host>:8443/api/v1/manifest.json | jq .
```

Then install the exact `bundle_url` from the manifest.

Notes:

- If mDNS hostname (`ota-gw.local`) is not resolvable on your LAN, use the
  server IP in the install URL for manual testing.
- Ensure the server certificate SAN matches the URL host you use (DNS name or IP).

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

Build-time guard:

- implemented in reusable class:
  `meta-iot-gateway/classes/iotgw-rauc-adaptive-guard.bbclass`
- when `IOTGW_RAUC_ADAPTIVE = "1"`, the class task validates IoT Gateway RAUC
  WKS root slot geometry (`rootA` and `rootB` `--fixed-size`) is a 4096-byte
  multiple
- build fails early if either adaptive root slot is missing or misaligned
- image build also validates generated WIC partition geometry via
  `do_iotgw_validate_wic_alignment` in
  `meta-iot-gateway/classes/iotgw-rauc-image.bbclass`

If not aligned, RAUC logs an adaptive mode error and falls back to normal full
write, for example:

```text
Continuing after adaptive mode error: ... image/partition size (...) is not a multiple of 4096 bytes
```

### Verify Slot Alignment (target)

```bash
for p in /dev/mmcblk0p3 /dev/mmcblk0p4; do
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
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /uboot-env
head -n1 /etc/fw_env.config
fw_printenv
fw_setenv iotgw_test 2
```

Typical causes:

- legacy layout: `/boot` is mounted read-only while RAUC needs to update
  `/boot/uboot.env`
- dedicated-env layout: `/uboot-env` is unavailable while RAUC needs to update
  `/uboot-env/uboot.env`

Use the wrapper command for manual installs:

```bash
iotgw-rauc-install <bundle>.raucb
```

For low-level debugging (skip systemd-run dispatch):

```bash
iotgw-rauc-install --direct <bundle>.raucb
```

If `rauc-mark-good.service` unexpectedly appears masked after update, check for
stale overlay masks in `/data/overlays/etc/upper/systemd/system/`.

### OTA mTLS CA Consistency

If streaming installs fail with TLS issuer/chain errors, verify the OTA CA used
by the server matches the device trust chain:

```bash
openssl verify -CAfile /etc/ota/ca.crt /etc/ota/device.crt
openssl x509 -in /etc/ota/ca.crt -noout -subject -fingerprint -sha256
```

For build-time alignment, set:

```bash
RAUC_OTA_CA_DIR = "/path/to/ota-dev-ca"
```

The `ota-certs` recipe accepts either `ca.crt/ca.key` or
`dev-ca.crt/dev-ca.key` in `RAUC_OTA_CA_DIR` and seeds `/etc/ota/ca.crt`.

### What To Do If Misaligned

- Fix `WKS_FILE` so `rootA` and `rootB` use aligned `--fixed-size` values.
- Rebuild the bundle with adaptive mode enabled and confirm the gate passes.
- If deployed devices are already on a non-aligned partition layout, keep
  adaptive mode disabled for those devices until they are reflashed.
