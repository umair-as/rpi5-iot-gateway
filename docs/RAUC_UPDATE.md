<div align="center">

# 🛠️ RAUC Update Runbook

**On-target operations, validation, and troubleshooting**

</div>

For architecture and design, see [OTA Updates](OTA_UPDATE.md).

---

## 📦 Installing a Bundle

> 🔐 **Bundles are encrypted by default.** The device decrypts with the private
> key at `/etc/ota/device.key`, named by the `[encryption]` stanza in
> `/etc/rauc/system.conf`. A freshly flashed device has none, so **provision
> before updating** — see
> [OTA Updates](OTA_UPDATE.md#-encryption-identity--three-locations-three-different-roles).
> The symptom of skipping it is an install that fails with
> `Encrypted bundle detected, but no decryption key given.`
>
> To check an artifact before shipping it:
> `rauc info --no-verify <bundle>.raucb` and read the `Bundle Format:` line
> (`crypt [encrypted CMS]` is the shippable state).

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

The boot environment holds only the RAUC slot-selection state (`BOOT_ORDER`,
`BOOT_A_LEFT`, `BOOT_B_LEFT`, `bootcount`), which RAUC writes through
`fw_setenv`. There are no runtime feature switches: network boot is not
compiled in, and the board's factory MAC is read from OTP on every boot.
Variable list and prod write policy:
[U-Boot Hardening](UBOOT_HARDENING.md#env-based-rauc-slot-selection).

On dev builds the U-Boot prompt is reachable by typing `igw` during the 2s
autoboot window; prod builds have no prompt.

---

## Shared boot files

An install writes the target root slot and that slot's signed FIT
(`/boot/fitImage-a` or `-b`), nothing else on `/boot`. `u-boot.bin`,
`config.txt` and `bcm2712-rpi-5-b.dtb` (U-Boot's FIT trust anchor) are
single-copy: a slot switch cannot roll them back, so a bad write there would
take both slots down.

**Before any slot is written**, the system pre-install handler
(`/usr/libexec/iotgw/iotgw-rauc-preinstall`, `[handlers]` in
`/etc/rauc/system.conf`) refuses a bundle unless:

- it declares `[meta.iotgw] bundle-abi=2` (its hook installs only the slot FIT);
- its rootfs image runs the bundle's pre-install and post-install hooks, and
  the bundle carries the hook, `bootfiles-fit.tar.gz` and exactly one
  `*.fitImage-a` and one `*.fitImage-b`;
- the current anchor on `/boot` accepts both slot FITs: by
  `required-mode` and the RSA key (modulus and exponent) behind each FIT
  signer, not by key name.

`bundle-formats` in `system.conf` refuses `plain` bundles before that. A
refusal is logged by RAUC (`journalctl -u rauc`) with the reason, and every
slot is left as it was.

**To change the shared files**, run the updater from an image that carries
the new ones:

```bash
sudo iotgw-rpi-bootfiles-update --dry-run    # plan; writes nothing
sudo iotgw-rpi-bootfiles-update              # back up, write, read back (asks first)
sudo reboot
sudo iotgw-rpi-bootfiles-update --restore <run-id>   # roll back a run (ls /data/rpi-boot/backup)
```

It refuses before the first write if a staged file does not match its
manifest, `/boot` is not a mounted read-write FAT, or the new DTB would not
accept an installed slot FIT. Each file is written to a temporary name, read
back from the medium, renamed and read back again. A `--restore` goes through
the same checks. Moving a device from dual trust to YubiKey-only trust is
staged: [FIT Boot Signing](FIT_BOOT_SIGNING.md).

## 📐 Adaptive Updates (block-hash-index)

Adaptive updates are not applied: they have not been validated against the
raw dm-verity slot image, and `IOTGW_RAUC_ADAPTIVE = "1"` is ignored with a
build warning.

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

### Slot not marked good after an update

`/etc` comes from the slot image on every boot (tmpfs upper layer, nothing
persisted on `/data`), so a stale mask cannot hide `rauc-mark-good.service`.
If the unit was skipped, check whether the boot is degraded and the slot is
still on trial since its install:

```bash
cat /run/iotgw/degraded 2>/dev/null
cat /uboot-env/iotgw-trial-slot 2>/dev/null
journalctl -b -u rauc-mark-good.service
```

A degraded boot of a slot on trial is deliberately not marked good, so its
boot counter falls back to the previous slot
([Persistent State Architecture](PERSISTENT_STATE.md#degraded-boot-no-usable-data)).

### OTA'd kernel not booting (kernel ↔ module mismatch)

Symptom after a bundle OTA: the slot boots, but `uname -r` shows the
*old* kernel while the rootfs carries the new modules — so `lsmod` is
empty, network/Bluetooth never come up, and `/lib/modules/$(uname -r)/`
is missing.

Cause: a stale `iotgw_load_boot` in the saved U-Boot env. On **dev**
builds the full saved env is imported, so a device whose saved env predates
the current `iotgw_load_boot` keeps the old script, and `bootcmd`'s
`saveenv` re-persists it every boot. That script may load a FIT other than
the slot's own `fitImage-<a|b>`; under dm-verity that FIT's command line does
not match the slot, so the slot either boots the wrong kernel or fails to
assemble its root. This stays invisible until an OTA ships a *different*
kernel version to one slot. **Prod is immune** — `CONFIG_ENV_WRITEABLE_LIST` makes the
boot scripts read-only, so the compiled-in per-slot logic always wins.

A bundle OTA repairs this automatically: the post-install hook reconciles
the boot-critical env against the canonical `uboot-env.txt` shipped in the
bundle, correcting a stale `iotgw_load_boot` without touching runtime state
(`BOOT_ORDER`, slot counters). The manual remediation below is only for a
device that cannot take such a bundle.

Diagnose (on target):

```bash
uname -r                                    # running kernel
sha256sum /boot/fitImage-a /boot/fitImage-b
fw_printenv iotgw_load_boot                 # current = per-slot ${_fit}, "no fallback"
scripts/ota/ota-fit-slot-check.sh           # asserts active-slot FIT == running kernel
```

Manual remediation (dev builds): repoint the stale var to the per-slot loader, reboot:

```bash
fw_setenv iotgw_load_boot 'if test "x${rauc_slot}" = "xA"; then setenv _fit fitImage-a; elif test "x${rauc_slot}" = "xB"; then setenv _fit fitImage-b; else setenv _fit fitImage-none; fi; if fatload mmc 0:1 ${iotgw_fit_addr_r} ${_fit}; then echo [IOTGW] FIT ${_fit} loaded; else echo [IOTGW] FIT ${_fit} load failed, no fallback; setenv BOOT_${rauc_slot}_LEFT 0; saveenv; reset; fi'
reboot
```

Or, at the U-Boot prompt, `env default -a; saveenv` to drop all stale
vars, then re-set `BOOT_ORDER` as needed.

### Encrypted bundle refused on target

```
Encrypted bundle detected, but no decryption key given.
```

The bundle is `crypt` (the default) and the device has no usable decryption
identity. Either `/etc/ota/device.key` is missing — a freshly flashed device,
before provisioning — or `/etc/rauc/system.conf` has no `[encryption]` stanza,
meaning the image itself was built with the verity opt-out while the bundle was
not. Confirm both halves:

```bash
# on target
grep -A3 '^\[encryption\]' /etc/rauc/system.conf; ls -l /etc/ota/device.key
# on host
rauc info --no-verify <bundle>.raucb
```

Re-provision with `scripts/ota/ota-certs-sync.sh`: it uploads the material to
`/data/ota/certs` and restarts `ota-certs-provision.service`, which copies it
into `/etc/ota`. `/etc` is volatile (tmpfs upper), so the service repeats the
copy on every boot.

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
- [Persistent State Architecture](PERSISTENT_STATE.md) — what persists across an OTA
- [Partition Layouts](PARTITIONS.md) — slot sizing
