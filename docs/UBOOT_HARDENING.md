# U-Boot Hardening

Architecture, design decisions, and implementation reference for U-Boot
hardening on the IoT Gateway OS.

---

## Overview

U-Boot is the highest-privilege software stage this project controls. The
Raspberry Pi 5 boot chain (BCM2712 ROM -> firmware -> BL31 -> U-Boot) does
not offer hardware-verified secure boot before U-Boot, so hardening begins
at the U-Boot policy layer.

The hardening work addresses three objectives:

1. **Enforce signed boot** — move from *verified-when-signed* to
   *required-to-be-signed* by disabling legacy image format.
2. **Reduce attack surface** — remove commands unused in the appliance
   boot path.
3. **Lock production environment** — prevent runtime mutation of boot
   policy variables from the U-Boot console.

All changes are additive to the existing FIT signing infrastructure
documented in [FIT Boot and Signing](FIT_BOOT_SIGNING.md) and preserve
full [RAUC A/B update](OTA_UPDATE.md) compatibility.

---

## Design Philosophy

### Modular feature tokens

Hardening is not monolithic. A single variable `IOTGW_UBOOT_FEATURES`
controls which hardening layers are active, using the same token pattern
as `IOTGW_KERNEL_FEATURES`:

| Token | Purpose | Safe for dev? |
|-------|---------|---------------|
| `surface_reduce` | Disable unused commands | Yes |
| `fit_enforce` | Disable legacy image format | Yes |
| `appliance_lockdown` | Console/env protection | No — prod only |

Tokens are additive. Any combination produces a valid build. Developers
choose their hardening posture; production images enforce the full set.

### Hybrid layering

The implementation uses two complementary mechanisms:

1. **Defconfig patch** (`0003-defconfig-iotgw-base.patch`) — Kconfig-
   validated baseline produced via `savedefconfig`. Captures resolved
   dependencies for FIT infrastructure, bootcount, autoboot, env
   partition, and headless profile. Regenerate on U-Boot version bumps
   using the devtool workflow.

2. **Conditional cfg fragments** — tokenized Kconfig overlays applied on
   top of the defconfig. Each fragment maps 1:1 to a feature token and
   is included via inline Python in the bbappend.

Why hybrid: defconfig gives a stable, Kconfig-validated foundation.
Fragments give policy flexibility without touching the base.

### Dev/prod separation

| Image | `IOTGW_UBOOT_FEATURES` | `BOOTDELAY` |
|-------|------------------------|-------------|
| `iot-gw-image-base` / `iot-gw-image-dev` | `surface_reduce fit_enforce` | `2` (keyed autoboot, type `igw`) |
| `iot-gw-image-prod` | `surface_reduce fit_enforce appliance_lockdown` | `-2` (no interactive window) |

The `IOTGW_UBOOT_BOOTDELAY` variable handles the meta-raspberrypi
BOOTDELAY override — meta-raspberrypi forces `-2` via
`do_configure:append`; our layer counteracts with a higher-priority
append that restores `2` for dev and keeps `-2` for prod.

---

## Architecture

### Boot flow

```
BCM2712 ROM
  -> RPi firmware (config.txt, DTB, overlays)
    -> BL31 (TF-A)
      -> U-Boot (IoT-Gateway)
        -> iotgw_rauc_select   (A/B slot selection, bootcount decrement)
        -> iotgw_set_bootargs  (PARTUUID root=, rauc.slot=)
        -> iotgw_load_boot     (per-slot FIT: fitImage-a / fitImage-b)
        -> iotgw_exec_fit      (bootm with FIT config + signature verify)
          -> Linux kernel
```

### Env-based RAUC slot selection

The RAUC A/B boot logic is compiled into U-Boot's default environment
via the `rpi.env` board environment patch (`0001-rpi-env-minimize-boot-
scanning`). Key variables:

| Variable | Purpose | Writable? |
|----------|---------|-----------|
| `BOOT_ORDER` | Slot priority (`A B` or `B A`) | Yes (RAUC) |
| `BOOT_A_LEFT` / `BOOT_B_LEFT` | Remaining boot attempts | Yes (RAUC) |
| `rauc_slot` | Selected slot for this boot | Runtime |
| `bootcount` | Boot attempt counter | Yes (RAUC) |
| `iotgw_appliance` | Appliance mode gate | Read-only (prod) |
| `iotgw_enable_netboot` | Netboot gate | Read-only (prod) |

In production (`appliance_lockdown`), appliance variables are locked via
`CONFIG_ENV_FLAGS_LIST_STATIC` and `CONFIG_ENV_ACCESS_IGNORE_FORCE`.

### Per-slot FIT naming

Each RAUC slot writes its kernel as a named FIT image on the shared boot
partition:

```
/boot/fitImage-a   <- slot A kernel
/boot/fitImage-b   <- slot B kernel
/boot/fitImage     <- fallback (first boot / migration)
```

U-Boot selects the correct FIT based on `rauc_slot`. The RAUC bundle
post-install hook (`bundle-hooks-fit.sh`) handles the slot-specific
naming.

---

## What is hardened

### Surface reduction (`surface_reduce`)

Commands removed from the U-Boot binary:

| Category | Disabled options |
|----------|-----------------|
| Network | `CMD_NET`, `CMD_DHCP`, `CMD_TFTPBOOT`, `CMD_NFS`, `CMD_PXE`, `CMD_WGET`, `CMD_DNS` |
| Memory inspection | `CMD_MD`, `CMD_MM`, `CMD_MW`, `CMD_MX`, `CMD_CRC32` |
| Legacy load | `CMD_LOADB`, `CMD_LOADS`, `CMD_FLASH`, `CMD_IMLS` |
| USB | `CMD_USB`, `USB_STORAGE` |
| Information disclosure | `CMD_LICENSE`, `CMD_BDINFO` |
| Boot script | `CMD_SOURCE` (prevents `boot.scr` fallback) |

**Preserved:** `CMD_BOOTM`, `CMD_BOOTI`, `CMD_FDT`, `CMD_MMC`,
`CMD_EXT4`, `CMD_FAT`, `CMD_BOOTSTAGE`, `CMD_SAVEENV`, `CMD_SETEXPR`
(needed by RAUC bootcount decrement).

Stack protector (`CONFIG_STACKPROTECTOR=y`) is enabled via the native
U-Boot wiring.

### FIT enforcement (`fit_enforce`)

```
CONFIG_LEGACY_IMAGE_FORMAT=n
```

In U-Boot 2025.04, `CONFIG_FIT_SIGNATURE` already disables legacy image
format by default when signature verification is active. The explicit
`LEGACY_IMAGE_FORMAT=n` reinforces this to prevent accidental
re-enablement.

Note: `CONFIG_FIT_SIGNATURE_ENFORCE` was removed upstream in U-Boot
2025.04. The enforcement is now implicit with `FIT_SIGNATURE=y`.

### Production lockdown (`appliance_lockdown`)

| Protection | Mechanism |
|------------|-----------|
| No interactive boot window | `CONFIG_BOOTDELAY=-2` |
| Autoboot keyed prompt disabled | `CONFIG_AUTOBOOT_KEYED=n` |
| Interactive env edit removed | `CONFIG_CMD_EDITENV=n` |
| Env write allowlist | `CONFIG_ENV_WRITEABLE_LIST=y` |
| Force flag blocked | `CONFIG_ENV_ACCESS_IGNORE_FORCE=y` |
| Appliance vars read-only | `CONFIG_ENV_FLAGS_LIST_STATIC` |
| `EXTRA_KERNEL_ARGS` runtime injection | Blocked — not on writeable list (explicit `:sr`) |

### Runtime cmdline tuning: `EXTRA_KERNEL_ARGS` (dev-only)

The compiled-in `iotgw_set_bootargs` U-Boot env honours `EXTRA_KERNEL_ARGS`
when set: its value is appended to the kernel cmdline after `root=PARTUUID`
and `rauc.slot=`. This is the documented runtime cmdline-tuning escape
hatch (`fw_setenv EXTRA_KERNEL_ARGS "cma=256M"`, etc. — see
[KERNEL.md](KERNEL.md)).

**Dev images** (`surface_reduce + fit_enforce` only): the variable is
freely writable. A root operator can set/clear it via `fw_setenv` and
the value reaches `/proc/cmdline` on the next boot.

**Production images** (`appliance_lockdown` adds env-writeable-list
enforcement): `EXTRA_KERNEL_ARGS` is **not** on the whitelist (explicit
`:sr` entry in `CONFIG_ENV_FLAGS_LIST_STATIC`), and `CONFIG_ENV_ACCESS_IGNORE_FORCE=y`
blocks the `-f` bypass. Writes are rejected at the U-Boot env layer.
The `if test -n "${EXTRA_KERNEL_ARGS}"` branch in `iotgw_set_bootargs`
becomes dead code at runtime — the variable can never become non-empty.

This matches the threat-model row "Env lockdown | Tampering | Prevent
runtime boot policy override". Runtime kernel-args injection *is* a boot
policy override; in prod it's blocked, in dev it's an intentional
operator escape hatch.

If a deployed prod fleet ever needs cmdline tuning, use a signed-image path:
set build-time policy variable `IOTGW_UBOOT_EXTRA_KERNEL_ARGS` in the image
build inputs.

`IOTGW_UBOOT_EXTRA_KERNEL_ARGS` is consumed by provisioning policy wiring:
`iotgw-provision.sh` applies it to U-Boot env only where runtime env writes are
allowed (dev posture). Under `appliance_lockdown`, runtime writes are rejected
by design, so production remains signed-image-driven.

### OTA env-refresh caveat

`iotgw_set_bootargs` itself is a *compiled-in default* in U-Boot. Once a
device has run `bootcmd` (which calls `saveenv` after assembling
bootargs), the persisted env in `/uboot-env/uboot.env` keeps whatever
`iotgw_set_bootargs` value was current at that save. Subsequent boots
load from persisted env, **not** the new compiled-in default.

This means: when the U-Boot binary is updated via RAUC OTA (e.g., the
fix that activated `EXTRA_KERNEL_ARGS` honouring), the persisted env
still has the old `iotgw_set_bootargs` and the new behaviour doesn't
take effect. Recovery is a one-time `env default iotgw_set_bootargs;
saveenv` from the U-Boot prompt. Fresh WIC flashes pick up the new
default automatically.

Automation is now in place: provisioning (`iotgw-provision.sh`) detects stale
persisted `iotgw_set_bootargs` values on non-lockdown images and clears them so
the updated compiled default takes effect on the next boot.

On `appliance_lockdown` images, this reconciliation is intentionally skipped
because the env writeable-list blocks such writes by policy.

### Larger FIT kernels: `SYS_BOOTM_LEN`

To support larger compressed FIT kernel payloads, the project carries:

```
CONFIG_SYS_BOOTM_LEN=0x8000000
```

via patch
`0004-configs-rpi_arm64_defconfig-increase-SYS_BOOTM_LEN-for-larger-fit-kernels.patch`.
This prevents bootm decompression buffer exhaustion as kernel/FIT payload size
grows (for example when debug/BTF metadata is enabled in dev lanes).

### Production key guard

`iotgw-uboot-prod-key-guard.bbclass` prevents production image builds
with a development-named FIT signing key. If `UBOOT_SIGN_KEYNAME`
contains `dev` and the build has prod intent (prod image or
`appliance_lockdown` token), `bb.fatal()` stops the build with a
diagnostic pointing to the key ceremony procedure.

---

## Explicit deferrals

These items were evaluated and deliberately excluded:

| Item | Reason |
|------|--------|
| BCM2712 OTP customer-key fusing | Irreversible; deferred pending manufacturing and recovery procedures |
| Signed `boot.img` container | Requires OTP policy; larger architectural change not justified by threat model |
| Measured boot (PCR extend in U-Boot) | TPM SPI access requires PCIe/RP1 driver chain not upstream in U-Boot |
| UEFI Secure Boot via EDK2 | Inappropriate for appliance-class gateway; adds complexity without security benefit |
| ECDSA FIT signing | RPi5 U-Boot `UCLASS_ECDSA` verify backend not validated; RSA-2048 is the supported path |

---

## Defconfig regeneration

When U-Boot is bumped to a new version, the `0003-defconfig-iotgw-base.patch`
must be regenerated. Use the devtool workflow:

```bash
kas shell kas/local.yml
devtool modify --no-overrides u-boot
cd build/workspace/sources/u-boot

# Generate baseline
make rpi_arm64_defconfig
make savedefconfig
cp defconfig defconfig.upstream

# Merge project fragments
scripts/kconfig/merge_config.sh .config /path/to/project-fragment.cfg

# Capture resolved config
make savedefconfig

# Commit only the defconfig
git add configs/rpi_arm64_defconfig
git commit -m "defconfig: apply iotgw base hardening"

# Write back to layer
devtool finish u-boot meta-iot-gateway/
```

The `--no-overrides` flag is required because the bbappend uses
conditional `SRC_URI:append` expressions that break devtool's default
override-branch processing.

---

## Threat model mapping

Each hardening layer maps to STRIDE categories from
[THREAT_MODEL.md](THREAT_MODEL.md):

| Layer | STRIDE | Control |
|-------|--------|---------|
| Surface reduction | Elevation of Privilege | Remove unused command vectors |
| FIT enforcement | Tampering, Spoofing | Reject unsigned/legacy boot payloads |
| Stack protector | Tampering | Memory corruption mitigation |
| Key guard | Spoofing (supply chain) | Prevent dev-key images in production |
| Env lockdown | Tampering | Prevent runtime boot policy override |

**Acknowledged gaps:**
- U-Boot console remains compiled in (field diagnostics); mitigated by
  `BOOTDELAY=-2` on prod
- Malformed env partition can prevent boot; mitigated by RAUC bootcount
  rollback
- No audit trail from U-Boot; Linux audit is the sole record

---

## References

- [FIT Boot and Signing](FIT_BOOT_SIGNING.md)
- [RAUC OTA Updates](OTA_UPDATE.md)
- [Security Hardening](SECURITY.md)
- [Threat Model](THREAT_MODEL.md)
- [Partition Layouts](PARTITIONS.md)
- [U-Boot FIT Signature docs](https://docs.u-boot.org/en/latest/usage/fit/signature.html)
