# FIT Image Setup and Signing Guide

This guide covers FIT boot flow setup, manual key generation, and FIT signature verification for the IoT Gateway project.

## Configure FIT Flow
In `kas/local.yml`, ensure FIT flow is selected:

```yaml
local_conf_header:
  kernel_mode_switch: |
    IOTGW_BOOT_FLOW = "fit"
```

Expected FIT overrides (already in this project):
- `PREFERRED_PROVIDER_virtual/kernel:fitflow = "linux-iotgw-mainline-fit"`
- `KERNEL_IMAGETYPE:fitflow = "fitImage"`
- `KERNEL_CLASSES:fitflow = " kernel-fitimage "`
- `KERNEL_BOOTCMD:fitflow = "bootm"`

### Optional: Enable Project-Owned Custom ITS
Default behavior remains Yocto auto-generated ITS. To opt in to project-owned
custom ITS mode:

```yaml
local_conf_header:
  fit_custom_its: |
    IOTGW_FIT_CUSTOM_ITS:fitflow = "1"
```

Notes:
- Default is `0` (OFF).
- Template path:
  `meta-iot-gateway/recipes-kernel/linux/files/iotgw-fit-single.its.in`
- Current template targets `broadcom/bcm2712-rpi-5-b.dtb` by default.
- Current template supports multi-config layout:
  - kernels: `kernel-1`, `kernel-2`
  - configs: `conf-primary` (primary), `conf-recovery` (secondary)

Optional custom ITS selection overrides:

```yaml
local_conf_header:
  fit_custom_its: |
    IOTGW_FIT_CUSTOM_ITS:fitflow = "1"
    IOTGW_FIT_CUSTOM_ITS_DEFAULT_CONF:fitflow = "conf-primary"
    # Default kernel-2 mode: auto-generate from local build artifacts.
    IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG:fitflow = "gzip"
    IOTGW_FIT_CUSTOM_ITS_REQUIRE_DISTINCT_KERNELS:fitflow = "1"
    # Optional recovery-kernel mode: provide an independent kernel-2 payload.
    # IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH:fitflow = "/abs/path/to/linux-alt.bin"
    # IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG:fitflow = "gzip"  # none|gzip|lzo
```

Notes:
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG` applies only to auto-generated
  kernel-2 payloads.
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG` applies when
  `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH` is set.

Concrete wiring for independent recovery-kernel mode:

```yaml
local_conf_header:
  fit_custom_its: |
    IOTGW_FIT_CUSTOM_ITS:fitflow = "1"
    IOTGW_FIT_STRATEGY_A_RECOVERY_KERNEL:fitflow = "1"
    IOTGW_FIT_RECOVERY_KERNEL_RECIPE:fitflow = "linux-iotgw-mainline-recovery"
    IOTGW_FIT_RECOVERY_KERNEL_PATH:fitflow = "${DEPLOY_DIR_IMAGE}/linux-recovery.bin"
    IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG:fitflow = "gzip"
```

When enabled:
- Recovery kernel artifact for FIT `kernel-2`: `linux-recovery.bin`
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG` controls how recovery payload
  is staged in FIT (`none|gzip|lzo`). Recommended default: `gzip`.

Important compatibility note:
- If recovery boots the normal rootfs, keep recovery and primary kernel configs
  module-ABI compatible (same effective module ABI options), otherwise modules
  fail to load with `Exec format error` / `this_module` size mismatch.

## Generate FIT Signing Keys (Manual)
Use a dedicated keypair (do not reuse RAUC or mTLS keys):

```bash
FIT_KEY_DIR="${IOTGW_RAUC_KEY_DIR}/fit"  # or any secure directory
install -d -m 700 "$FIT_KEY_DIR"
openssl genrsa -out "$FIT_KEY_DIR/iotgw-fit-dev.key" 2048
openssl req -new -x509 \
  -key "$FIT_KEY_DIR/iotgw-fit-dev.key" \
  -out "$FIT_KEY_DIR/iotgw-fit-dev.crt" \
  -days 3650 \
  -subj "/CN=iotgw-fit-dev/O=IoT Gateway Dev/OU=FIT Signing"
chmod 600 "$FIT_KEY_DIR/iotgw-fit-dev.key"
chmod 644 "$FIT_KEY_DIR/iotgw-fit-dev.crt"
```

## Enable FIT Signing in Local Config
In `kas/local.yml` (local-only, gitignored), use the project's `fit_signing_dev` block:

```yaml
local_conf_header:
  fit_signing_dev: |
    IOTGW_FIT_SIGNING = "1"
    IOTGW_FIT_SIGN_MODE = "rsa"
    UBOOT_SIGN_ENABLE:fitflow = "1"
    FIT_HASH_ALG:fitflow = "sha256"
    FIT_SIGN_ALG:fitflow = "rsa2048"
    FIT_GENERATE_KEYS:fitflow = "0"
    UBOOT_SIGN_KEYDIR:fitflow = "/path/to/your/fit-keys"
    UBOOT_SIGN_KEYNAME:fitflow = "iotgw-fit-dev"
```

Notes:
- `FIT_GENERATE_KEYS = "0"` keeps key management manual.
- Non-FIT flow remains unaffected.
- Replace `/path/to/your/fit-keys` with your actual key directory.
- This project currently validates FIT signing/verification with RSA.
- ECDSA path is not validated in this repository yet; do not treat it as a
  supported/verified production path.

## Ensure U-Boot Supports FIT Signature Verification
This project enables required U-Boot options via:
- `meta-iot-gateway/recipes-bsp/u-boot/files/iotgw-uboot.cfg`

Relevant options include:
- `CONFIG_FIT=y`
- `CONFIG_FIT_SIGNATURE=y`
- `CONFIG_RSA=y`
- `CONFIG_RSA_PUBLIC_KEY_PARSER=y`
- `CONFIG_SHA256=y`

## Build Signed FIT Bundle
Force rebuild of U-Boot and kernel artifacts after signing changes:

```bash
kas shell kas/local.yml -c 'bitbake -c cleansstate u-boot virtual/kernel'
make bundle-dev-full-fit
```

## Verify Signed FIT on Host
Check FIT structure:

```bash
dumpimage -l build/tmp-glibc/deploy/images/raspberrypi5/fitImage
```

Expected:
- kernel and FDT entries present
- hash nodes present (sha256)
- signature-related fields present when signing is enabled

If custom ITS mode is enabled, also inspect deployed ITS source:

```bash
ls build/tmp-glibc/deploy/images/raspberrypi5/fitImage-its-*.its
grep -nE 'kernel-1|kernel-2|configurations|default =|conf-primary|conf-recovery' \
  build/tmp-glibc/deploy/images/raspberrypi5/fitImage-its-*.its
```

Confirm kernel variants are distinct:

```bash
dumpimage -l build/tmp-glibc/deploy/images/raspberrypi5/fitImage | \
  grep -E 'Image [0-9] \(kernel-|Compression:|Hash value:'
```

Expected:
- Recovery-kernel mode enabled (`IOTGW_FIT_STRATEGY_A_RECOVERY_KERNEL = "1"`):
  - `kernel-1`: primary kernel payload
  - `kernel-2`: recovery payload from `linux-recovery.bin`
- Recovery-kernel mode disabled:
  - `kernel-2` is auto-generated according to
    `IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG`

To test runtime config selection on target (U-Boot env):

```bash
fw_printenv iotgw_fit_conf iotgw_fit_conf_default
fw_setenv iotgw_fit_conf conf-recovery
reboot
```

Verify FIT bundle payload uses FIT bootfiles:

```bash
tmpd=$(mktemp -d)
7z x -y -o"$tmpd" build/tmp-glibc/deploy/images/raspberrypi5/iot-gw-image-dev-bundle-full-fit.raucb >/dev/null
sed -n '1,200p' "$tmpd/manifest.raucm"
tar -tzf "$tmpd/bootfiles-fit.tar.gz" | grep -E 'boot.scr|fitImage'
rm -rf "$tmpd"
```

## Install and Verify on Target
Install bundle and reboot:

```bash
iotgw-rauc-install <url>/iot-gw-image-dev-bundle-full-fit.raucb
reboot
```

Validate boot mode:

```bash
strings /boot/boot.scr | grep -E "Image:|fatload|bootm|booti"
ls -l /boot/fitImage /boot/Image
rauc status
```

Expected:
- `Image: fitImage`
- `fatload ... fitImage`
- `bootm ...`
- `/boot/fitImage` exists

Check U-Boot log for verification path:
- FIT configuration selected
- hash verification success lines
- no `Bad Data Hash` / `Unsupported hash algorithm`

Quick functional checks after booting `conf-recovery`:

```bash
lsmod | head
ip -4 a
dmesg | grep -E "this_module|Exec format error|Bad Data Hash|Unsupported hash algorithm"
```

Expected:
- modules load normally (`lsmod` non-empty)
- recovery network interfaces are present
- no module ABI mismatch errors

## Negative Test (Tamper Protection)
Goal: confirm tampered FIT does not boot.

Suggested method:
1. Backup `/boot/fitImage` on target.
2. Modify one byte in `/boot/fitImage`.
3. Reboot and confirm U-Boot verification failure.
4. Restore backup and reboot.

Example (careful, test device only):

```bash
cp /boot/fitImage /boot/fitImage.bak
printf '\x00' | dd of=/boot/fitImage bs=1 seek=4096 count=1 conv=notrunc
sync
reboot
```

Expected failure symptoms in U-Boot log:
- hash/signature verification error
- kernel not booted

## Production Notes
- Use separate production FIT signing keys.
- Keep production private keys offline/HSM-managed.
- Do not commit keys into repository.
- Keep RAUC signing keys and FIT signing keys separate.
