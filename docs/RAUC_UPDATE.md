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

### OTA'd kernel not booting (kernel ↔ module mismatch)

Symptom after a bundle OTA: the slot boots, but `uname -r` shows the
*old* kernel while the rootfs carries the new modules — so `lsmod` is
empty, network/Bluetooth never come up, and `/lib/modules/$(uname -r)/`
is missing.

Cause: U-Boot loaded the stale shared `/boot/fitImage` instead of the
per-slot `fitImage-<a|b>` the post-install hook wrote. On **dev** builds
the full saved U-Boot env is imported, so a device whose saved env
predates the per-slot `iotgw_load_boot` keeps the old script (which always
loads plain `fitImage`), and `bootcmd`'s `saveenv` re-persists it every
boot. This stays invisible until an OTA ships a *different* kernel version
to one slot. **Prod is immune** — `CONFIG_ENV_WRITEABLE_LIST` makes the
boot scripts read-only, so the compiled-in per-slot logic always wins.

A bundle OTA repairs this automatically: the post-install hook reconciles
the boot-critical env against the canonical `uboot-env.txt` shipped in the
bundle, correcting a stale `iotgw_load_boot` without touching runtime state
(`BOOT_ORDER`, slot counters). The manual remediation below is only for a
device that cannot take such a bundle.

Diagnose (on target):

```bash
uname -r                                    # running kernel
sha256sum /boot/fitImage /boot/fitImage-b   # per-slot FIT vs stale shared one
fw_printenv iotgw_load_boot                 # stale = plain fitImage, no per-slot ${_fit}
scripts/ota/ota-fit-slot-check.sh           # asserts active-slot FIT == running kernel
```

Manual remediation (dev builds): repoint the stale var to the per-slot loader, reboot:

```bash
fw_setenv iotgw_load_boot 'if test "x${rauc_slot}" = "xA"; then setenv _fit fitImage-a; elif test "x${rauc_slot}" = "xB"; then setenv _fit fitImage-b; else setenv _fit fitImage; fi; if fatload mmc 0:1 ${iotgw_fit_addr_r} ${_fit}; then echo [IOTGW] FIT ${_fit} loaded; elif fatload mmc 0:1 ${iotgw_fit_addr_r} fitImage; then echo [IOTGW] FIT fallback fitImage loaded; else echo [IOTGW] FIT load failed; setenv BOOT_${rauc_slot}_LEFT 0; saveenv; reset; fi'
reboot
```

Or, at the U-Boot prompt, `env default -a; saveenv` to drop all stale
vars, then re-set `BOOT_ORDER` as needed.

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
