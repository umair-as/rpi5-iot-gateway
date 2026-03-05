# FIT Image Setup and Signing Guide

This guide covers FIT boot flow setup, manual key generation, and FIT signature verification for the IoT Gateway project.

## Scope
- FIT kernel boot via U-Boot (`fitImage` + `bootm`)
- Manual dev keypair management for FIT signing
- Build-time FIT signing enablement
- Host and target verification steps
- Negative (tamper) test

## Prerequisites
- `kas` and Yocto build environment working
- `dumpimage` installed on host (`u-boot-tools`)
- Branch configured for FIT flow in `kas/local.yml`

## 1. Configure FIT Flow
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

### Optional: Enable Project-Owned Custom ITS (Phase A)
Default behavior remains Yocto auto-generated ITS. To opt in to project-owned
custom ITS mode:

```yaml
local_conf_header:
  fit_custom_its: |
    IOTGW_FIT_CUSTOM_ITS:fitflow = "1"
```

Notes:
- Default is `0` (OFF).
- Phase A template path:
  `meta-iot-gateway/recipes-kernel/linux/files/iotgw-fit-single.its.in`
- Current template targets `broadcom/bcm2712-rpi-5-b.dtb` by default.
- Current template supports multi-config layout:
  - kernels: `kernel-1`, `kernel-2`
  - configs: `conf-primary` (primary), `conf-recovery` (secondary)

Optional Phase B selection policy overrides:

```yaml
local_conf_header:
  fit_custom_its: |
    IOTGW_FIT_CUSTOM_ITS:fitflow = "1"
    IOTGW_FIT_CUSTOM_ITS_DEFAULT_CONF:fitflow = "conf-primary"
    # Strategy B (default): auto-generate kernel-2 from local build artifacts.
    IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG:fitflow = "gzip"
    IOTGW_FIT_CUSTOM_ITS_REQUIRE_DISTINCT_KERNELS:fitflow = "1"
    # Strategy A (optional): use an independent recovery kernel payload.
    # IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH:fitflow = "/abs/path/to/linux-alt.bin"
    # IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG:fitflow = "gzip"  # none|gzip|lzo
```

Notes:
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_COMP_ALG` applies only to auto-generated
  kernel-2 payloads (Strategy B).
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG` applies when
  `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH` is set (Strategy A).

Strategy A concrete wiring (independent recovery kernel build):

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
- `IOTGW_FIT_CUSTOM_ITS_KERNEL2_PATH_COMP_ALG` controls how Strategy A payload
  is staged in FIT (`none|gzip|lzo`). Recommended default: `gzip`.

Important compatibility note:
- If recovery boots the normal rootfs, keep recovery and primary kernel configs
  module-ABI compatible (same effective module ABI options), otherwise modules
  fail to load with `Exec format error` / `this_module` size mismatch.

## 2. Generate FIT Signing Keys (Manual)
Use a dedicated keypair (do not reuse RAUC or mTLS keys):

```bash
install -d -m 700 /home/umair/rauc-keys/fit
openssl genrsa -out /home/umair/rauc-keys/fit/iotgw-fit-dev.key 2048
openssl req -new -x509 \
  -key /home/umair/rauc-keys/fit/iotgw-fit-dev.key \
  -out /home/umair/rauc-keys/fit/iotgw-fit-dev.crt \
  -days 3650 \
  -subj "/CN=iotgw-fit-dev/O=IoT Gateway Dev/OU=FIT Signing"
chmod 600 /home/umair/rauc-keys/fit/iotgw-fit-dev.key
chmod 644 /home/umair/rauc-keys/fit/iotgw-fit-dev.crt
```

## 3. Enable FIT Signing in Local Config
In `kas/local.yml` (local-only), use the project's `fit_signing_dev` block:

```yaml
local_conf_header:
  fit_signing_dev: |
    IOTGW_FIT_SIGNING = "1"
    IOTGW_FIT_SIGN_MODE = "rsa"   # "rsa" (default) or "ecdsa"
    UBOOT_SIGN_ENABLE:fitflow = "1"
    FIT_HASH_ALG:fitflow = "sha256"
    FIT_SIGN_ALG:fitflow = "rsa2048"  # auto-switches to ecdsa256 when mode=ecdsa
    FIT_GENERATE_KEYS:fitflow = "0"
    UBOOT_SIGN_KEYDIR:fitflow = "/home/umair/rauc-keys/fit"
    UBOOT_SIGN_KEYNAME:fitflow = "iotgw-fit-dev"
```

Notes:
- `FIT_GENERATE_KEYS = "0"` keeps key management manual.
- Non-FIT flow remains unaffected.

### Optional: ECDSA Signing Mode
To test ECDSA, switch:

```yaml
IOTGW_FIT_SIGN_MODE = "ecdsa"
```

This selects:
- `FIT_SIGN_ALG = "ecdsa256"`
- `UBOOT_SIGN_KEYNAME = "iotgw-fit-ecdsa-dev"`

Generate matching ECDSA keys:

```bash
openssl ecparam -name prime256v1 -genkey -noout \\
  -out /home/umair/rauc-keys/fit/iotgw-fit-ecdsa-dev.key
openssl req -new -x509 \\
  -key /home/umair/rauc-keys/fit/iotgw-fit-ecdsa-dev.key \\
  -out /home/umair/rauc-keys/fit/iotgw-fit-ecdsa-dev.crt \\
  -days 3650 \\
  -subj "/CN=iotgw-fit-ecdsa-dev/O=IoT Gateway Dev/OU=FIT Signing"
chmod 600 /home/umair/rauc-keys/fit/iotgw-fit-ecdsa-dev.key
chmod 644 /home/umair/rauc-keys/fit/iotgw-fit-ecdsa-dev.crt
```

## 4. Ensure U-Boot Supports FIT Signature Verification
This project enables required U-Boot options via:
- `meta-iot-gateway/recipes-bsp/u-boot/files/iotgw-uboot.cfg`

Relevant options include:
- `CONFIG_FIT=y`
- `CONFIG_FIT_SIGNATURE=y`
- `CONFIG_ECDSA=y` and `CONFIG_ECDSA_VERIFY=y` (for ECDSA mode)
- `CONFIG_RSA=y`
- `CONFIG_RSA_PUBLIC_KEY_PARSER=y`
- `CONFIG_SHA256=y`

## 5. Build Signed FIT Bundle
Force rebuild of U-Boot and kernel artifacts after signing changes:

```bash
kas shell -c 'bitbake -c cleansstate u-boot virtual/kernel' kas/local.yml
make bundle-dev-full-fit
```

## 6. Verify Signed FIT on Host
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
  grep -E 'Image [0-9] \\(kernel-|Compression:|Hash value:'
```

Expected with current Strategy A:
- `kernel-1`: gzip compressed (primary kernel)
- `kernel-2`: gzip compressed (recovery kernel from `linux-recovery.bin`)

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

## 7. Install and Verify on Target
Install bundle and reboot:

```bash
rauc install <url>/iot-gw-image-dev-bundle-full-fit.raucb
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

## 8. Negative Test (Tamper Protection)
Goal: confirm tampered FIT does not boot.

Suggested method:
1. Backup `/boot/fitImage` on target.
2. Modify one byte in `/boot/fitImage`.
3. Reboot and confirm U-Boot verification failure.
4. Restore backup and reboot.

Example (careful, test device only):

```bash
cp /boot/fitImage /boot/fitImage.bak
printf '\\x00' | dd of=/boot/fitImage bs=1 seek=4096 count=1 conv=notrunc
sync
reboot
```

Expected failure symptoms in U-Boot log:
- hash/signature verification error
- kernel not booted

## 9. Production Notes
- Use separate production FIT signing keys.
- Keep production private keys offline/HSM-managed.
- Do not commit keys into repository.
- Keep RAUC signing keys and FIT signing keys separate.

## 10. Boot Timing Snapshot (Reference)
Use this as a reference format for future comparisons. Keep raw serial logs in
`/tmp/tio-session-logs/`; do not paste full logs into docs.

Observed on RPi5 dev board (single run each):
- Firmware handoff (`Starting OS`): primary ~6.27s, recovery ~6.43s
- FIT read from boot partition: ~77.99 MB in ~3.23s
- Kernel to init (`Run /sbin/init`): ~0.584s for both
- Kernel to eth0 link up: primary ~9.415s, recovery ~9.447s

Interpretation:
- Recovery boot path is functionally equivalent to primary for early boot.
- Most variability is from firmware/U-Boot jitter, not userspace.

## Related Files
- `kas/local.yml`
- `meta-iot-gateway/recipes-bsp/u-boot/files/iotgw-uboot.cfg`
- `meta-iot-gateway/recipes-kernel/linux/linux-iotgw-mainline-fit_6.18.bb`
- `meta-iot-gateway/recipes-ota/bundles/iot-gw-bundle-full-fit.bb`
