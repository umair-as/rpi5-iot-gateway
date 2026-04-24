<div align="center">

# 🛠️ RAUC Update Runbook

**On-target operations, validation, and troubleshooting**

</div>

For architecture and design, see [OTA Updates](OTA_UPDATE.md).

---

## 📦 Installing a Bundle

### Local install

```bash
iotgw-rauc-install <bundle>.raucb
```

### HTTPS streaming install

```bash
iotgw-rauc-install https://<ota-host>:8443/bundles/<bundle>.raucb
```

The wrapper handles `systemd-run` dispatch, OTA certificate
reconciliation, preflight connectivity check, and temporary `/boot`
rw remount. Use `--direct` to skip `systemd-run` dispatch (debug only).

### 📋 Track progress

```bash
journalctl --no-pager -fu rauc
journalctl --no-pager -t iotgw-rauc-install
```

---

## ✅ Checking Slot State

```bash
rauc status
```

After a successful install + reboot:
- ✅ System boots from the updated slot
- ✅ `rauc-mark-good.service` marks it as good
- ✅ `boot-backup-prune.service` cleans up old `/boot/*.bak*` artifacts

---

## 🌐 Streaming Preflight (mTLS)

Before remote installs, verify the cert chain and server reachability:

```bash
# Verify device cert chain
openssl verify -CAfile /etc/ota/ca.crt /etc/ota/device.crt

# Test manifest endpoint
curl --cert /etc/ota/device.crt \
     --key /etc/ota/device.key \
     --cacert /etc/ota/ca.crt \
     -fsS https://<ota-host>:8443/api/v1/manifest.json | jq .
```

> 💡 If mDNS hostname (`ota-gw.local`) is not resolvable, use the server IP. Ensure the server certificate SAN matches the URL host.

---

## ⚙️ U-Boot Environment Controls

| Variable | Default | Purpose |
|----------|---------|---------|
| `iotgw_appliance` | `1` | Appliance fast-path in board init |
| `iotgw_enable_netboot` | `0` | Enable netboot network path |
| `iotgw_diag` | `0` | Print RAUC vars + MMC info at boot |
| `iotgw_bootstage` | `1` | Print bootstage timing on serial |

On dev builds, toggle at the U-Boot prompt (type `igw` during the 2s
autoboot window). On prod builds (`appliance_lockdown`), appliance
variables are read-only — see [U-Boot Hardening](UBOOT_HARDENING.md).

```bash
# Enable field diagnostics
fw_setenv iotgw_diag 1

# Restore defaults
fw_setenv iotgw_appliance 1
fw_setenv iotgw_enable_netboot 0
fw_setenv iotgw_diag 0
fw_setenv iotgw_bootstage 1
```

---

## 📐 Adaptive Updates (block-hash-index)

When enabled (`IOTGW_RAUC_ADAPTIVE = "1"`), RAUC uses block-hash-index
mode requiring rootfs slot sizes to be 4 KiB aligned. Build-time guards
validate alignment automatically.

### Verify slot alignment

```bash
for p in /dev/mmcblk0p3 /dev/mmcblk0p4; do
  s=$(blockdev --getsize64 "$p")
  echo "$p size=$s mod4096=$((s%4096))"
done
# Expected: mod4096=0 for both slots
```

> ⚠️ If deployed devices have non-aligned partitions, keep adaptive mode disabled until they are reflashed.

---

## 🔧 Troubleshooting

### fw_setenv failures

If install fails with `Failed to run fw_setenv: Child process exited with code 247`:

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /uboot-env
head -n1 /etc/fw_env.config
fw_printenv BOOT_ORDER
```

Check that `/uboot-env` is mounted rw and `fw_env.config` has a single
entry matching U-Boot's env configuration.

### Stale overlay masks

If `rauc-mark-good.service` appears masked after update:

```bash
ls -la /data/overlays/etc/upper/systemd/system/rauc-mark-good.service
journalctl -b -t rauc | grep overlay-reconcile
```

The overlay reconciler removes these via the `absent` policy in
`managed-paths.conf`.

### mTLS CA mismatch

If streaming installs fail with TLS chain errors:

```bash
openssl verify -CAfile /etc/ota/ca.crt /etc/ota/device.crt
openssl x509 -in /etc/ota/ca.crt -noout -subject -fingerprint -sha256
```

Ensure `RAUC_OTA_CA_DIR` in `kas/local.yml` matches the OTA server's CA.

---

## 📚 References

- [OTA Updates](OTA_UPDATE.md) — architecture, feature-gating profiles
- [U-Boot Hardening](UBOOT_HARDENING.md) — env lockdown, boot flow
- [Overlay Reconciliation](OVERLAY_RECONCILIATION.md) — post-OTA config management
- [Partition Layouts](PARTITIONS.md) — slot sizing and alignment
