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
| `watchdog` | Enable BCM2835 watchdog command/driver with explicit boot policy | Evaluation only |
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

`BOOTDELAY` is compiled in (`CONFIG_BOOTDELAY`): `2` from `iotgw-uboot.cfg`,
`-2` from the `appliance_lockdown` fragment. There is no runtime setting for
it. meta-raspberrypi forces `-2` in its own `do_configure:append`; the layer's
U-Boot bbappend re-applies the intended value after it.

---

## Architecture

### Boot flow

```
BCM2712 ROM
  -> RPi firmware (config.txt, DTB, overlays)
    -> BL31 (TF-A)
      -> U-Boot (IoT-Gateway)
        -> iotgw_rauc_select   (A/B slot selection, bootcount decrement)
        -> iotgw_set_bootargs  (slot-partition check; clears env bootargs/fdt_addr so the FIT's own DTB and its /chosen/bootargs are used)
        -> iotgw_load_boot     (per-slot FIT: fitImage-a / fitImage-b)
        -> iotgw_exec_fit      (bootm <fit> -: signed default config with its own fdt; cmdline carries the dm-verity table)
          -> Linux kernel
```

When the optional `watchdog` U-Boot feature token is enabled, the boot
environment starts the BCM2712 watchdog (`watchdog@7d200000`, bcm2835-class
driver) at the beginning of `bootcmd` and stops it as the first step of
`iotgw_exec_fit`, immediately before `bootm`; it is also stopped before the
intentional all-slots-exhausted halt loop. The armed window therefore covers
U-Boot-side slot selection, bootargs, FIT loading (`fatload`), and env save.
FIT signature verification and kernel handoff happen inside `bootm`, *after*
the watchdog is stopped — so the kernel never inherits an armed timer, but the
signature-verify step itself is not watchdog-covered. Linux PID1 watchdog
feeding is a separate mechanism, on by default
(`IOTGW_ENABLE_SYSTEMD_HW_WATCHDOG=1`): systemd feeds `/dev/watchdog0` at
`RuntimeWatchdogSec=15s`, kept ≤ the ~16s BCM2712 hardware maximum.

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
| `ethaddr` / `usbethaddr` | Factory MAC, read from OTP at boot | Set by U-Boot only (prod) |

In production (`appliance_lockdown`), `CONFIG_ENV_WRITEABLE_LIST` imports
only the variables marked writeable in `CONFIG_ENV_FLAGS_LIST_STATIC` from
the stored environment; everything else comes from the built-in default, and
`CONFIG_ENV_ACCESS_IGNORE_FORCE` stops `setenv -f` overriding a read-only
variable.

**Board MAC.** U-Boot asks the firmware for the factory MAC on every boot
(the board code's `set_usbethaddr()`), sets `ethaddr`, and `bootm` writes it
into the `ethernet0` node of the FIT's signed device tree, after the signature
check, as it does for `/chosen`. The kernel's eth0, and br0 with it, therefore
keep the same address on every boot, including a degraded boot whose
machine-id is per boot. In prod an `ethaddr` placed in the stored environment
is refused at import (it is not writeable), so the address comes only from
OTP. Reading it is one firmware mailbox call; no network driver starts, and
network boot stays impossible (no `boot_targets` entry, no network commands;
see the command table below).

### Per-slot FIT naming

Each RAUC slot has its own named FIT image on the shared boot partition:

```
/boot/fitImage-a   <- slot A kernel + DTB (slot A dm-verity table)
/boot/fitImage-b   <- slot B kernel + DTB (slot B dm-verity table)
```

U-Boot selects the correct FIT based on `rauc_slot`. Both files are written at
flash time; an OTA rewrites the one for the slot it installs (the RAUC bundle
post-install hook, `bundle-hooks-fit.sh`). There is no fallback: a generic FIT
carries no verity table, so a missing slot FIT zeroes that slot's boot attempts
and resets.

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

**Preserved:** `CMD_BOOTM`, `CMD_BOOTI` (dev only; `appliance_lockdown`
removes it, see below), `CMD_FDT`, `CMD_MMC`,
`CMD_EXT4`, `CMD_FAT`, `CMD_BOOTSTAGE`, `CMD_SAVEENV`, `CMD_SETEXPR`
(needed by RAUC bootcount decrement).

Stack protector (`CONFIG_STACKPROTECTOR=y`) is enabled via the native
U-Boot wiring.

### FIT enforcement (`fit_enforce`)

```
CONFIG_LEGACY_IMAGE_FORMAT=n
```

In U-Boot 2026.01, `CONFIG_FIT_SIGNATURE` already disables legacy image
format by default when signature verification is active. The explicit
`LEGACY_IMAGE_FORMAT=n` reinforces this to prevent accidental
re-enablement.

Note: `CONFIG_FIT_SIGNATURE_ENFORCE` was removed upstream in U-Boot
2025.04. The enforcement is implicit with `FIT_SIGNATURE=y`.

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
| Unsigned boot paths removed | `CONFIG_CMD_BOOTI=n`, `CONFIG_CMD_GO=n` |

The last row is defence in depth. A dev U-Boot with `booti` boots an unsigned
raw kernel `Image` with any command line from its prompt, skipping FIT
verification entirely. On prod the lockdown above already leaves no way to
reach it (no prompt, `bootcmd` not loadable from the env), so removing the
commands only guards against a future boot-script bug. Signed-FIT `bootm` is
the only boot command left.

### Kernel command line: fixed at build time

The command line is the `/chosen/bootargs` of the slot's signed FIT device
tree: the firmware `cmdline.txt` content, `IOTGW_VERITY_KERNEL_ARGS`, and the
dm-verity table. `iotgw_set_bootargs` clears the environment `bootargs`, so no
U-Boot environment variable (`EXTRA_KERNEL_ARGS` included) reaches the kernel
on any image. Change the command line with `IOTGW_VERITY_KERNEL_ARGS` and
rebuild; the change is then covered by the FIT signature.

On prod, `EXTRA_KERNEL_ARGS` is additionally kept off the env writeable list
(lockdown table above).

### OTA env refresh

Boot scripts such as `iotgw_set_bootargs` and `iotgw_load_boot` are compiled-in
defaults, but a dev device's `bootcmd` `saveenv` persists them in
`/uboot-env/uboot.env`, so a new U-Boot binary alone does not change them. The
bundle post-install hook rewrites the boot-critical variables from the bundle's
`uboot-env.txt` (runtime state such as `BOOT_ORDER` / `BOOT_x_LEFT` is
untouched). Without a bundle, recovery is `env default <var>; saveenv` from the
U-Boot prompt; fresh WIC flashes pick up the new defaults. Prod imports only
writeable variables, so compiled-in scripts always win.

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
. scripts/env.sh && kas shell kas/local.yml
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
