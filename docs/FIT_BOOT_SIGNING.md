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

## DTB trust rotation: file key → YubiKey

The U-Boot **control FDT** (the runtime DTB the RPi firmware passes to
U-Boot) holds the public keys U-Boot trusts when verifying FIT
signatures at boot. Rotating from a file-key-only trust root to a
hardware-resident YubiKey pubkey is the second leg of FIT-signing
adoption: PR-side HSM signing produces FITs that only verify on devices
whose control FDT carries the corresponding pubkey.

This project ships a three-image rotation pattern modelled after the
RAUC PKI rotation (see `docs/RAUC_PKI.md`):

| Image | DTB trust roots | FIT signing key | Notes |
|-------|-----------------|-----------------|-------|
| A (legacy) | file key only | file key | Status quo before this rotation. |
| **B (transition)** | **file key + YK pubkey** | file key (build) or YK (post-build, optional) | DTB carries both pubkeys with `/signature/required-mode = "any"`. A FIT signed by either root verifies. |
| C (cutover) | YK pubkey only | YK (post-build, mandatory) | File key retired. `IOTGW_FIT_TRUST_FILE_KEY = "0"` in `kas/local.yml`. |

Image B is the only image that should ship while operators still hold
the legacy file-key private material. Devices that boot Image B will
accept any future YK-signed FIT, so the rotation can proceed without
re-flashing.

### Operator pre-flight: export the YK public certificate

The build host needs the public certificate from slot 9a. **No private
key is exported, ever.** Capture once into the operator key tree:

```bash
KEY_DIR="${IOTGW_RAUC_KEY_DIR}/rauc-ca/fit"
install -d -m 700 "$KEY_DIR"
ykman piv certificates export 9a "$KEY_DIR/iotgw-fit-yk-2026.crt"
chmod 644 "$KEY_DIR/iotgw-fit-yk-2026.crt"
openssl x509 -in "$KEY_DIR/iotgw-fit-yk-2026.crt" -noout -subject -dates
```

The certificate filename is `<IOTGW_FIT_YK_KEYNAME>.crt`; renaming the
YubiKey hint string in the project requires renaming this file in
lockstep. The default `iotgw-fit-yk-2026` is intentionally year-tagged
so a future rotation lands at `iotgw-fit-yk-<NEW_YEAR>` without
clobbering existing trust anchors on already-deployed Image B devices.

### Build-time configuration (Image B)

In `kas/local.yml`, enable both trust roots:

```yaml
local_conf_header:
  fit_dtb_yk_pubkey_trust: |
    IOTGW_FIT_TRUST_FILE_KEY:fitflow = "1"
    IOTGW_FIT_TRUST_YK_KEY:fitflow = "1"
    IOTGW_FIT_YK_KEYDIR:fitflow = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/fit"
    IOTGW_FIT_YK_KEYNAME:fitflow = "iotgw-fit-yk-2026"
```

Force rebuild of the kernel so the deploy step re-mutates the DTBs:

```bash
kas shell kas/local.yml -c 'bitbake -c cleansstate virtual/kernel'
make bundle-dev-full-fit
```

The kernel-fit recipe's `do_deploy:append` block:

- Loops over `RPI_KERNEL_DEVICETREE` DTBs.
- When `IOTGW_FIT_TRUST_FILE_KEY = "1"`: runs `mkimage -F -k -K -r` to
  sign the FIT with the file key AND inject the file-key public key
  into the DTB under `/signature/key-<UBOOT_SIGN_KEYNAME>`.
- When `IOTGW_FIT_TRUST_YK_KEY = "1"`: runs `fdt_add_pubkey -a
  ${FIT_HASH_ALG},${FIT_SIGN_ALG} -k <yk-keydir> -n <yk-keyname>
  -r conf` to add a second key node under
  `/signature/key-<IOTGW_FIT_YK_KEYNAME>` (no private key required), then
  sets `/signature/required-mode = "any"` via `fdtput` so a FIT signed by
  either root verifies.

Setting both gates to `"0"` with `UBOOT_SIGN_ENABLE=1` is fatal — the
recipe refuses to deploy unsigned-trust DTBs.

### Verifying the DTB build output

Inspect the deployed DTB:

```bash
DTB=build/tmp-glibc/deploy/images/raspberrypi5/bcm2712-rpi-5-b.dtb
fdtdump "$DTB" | sed -n '/signature {/,/};/p'
```

Expected structure:

```dts
signature {
    required-mode = "any";
    key-iotgw-fit-dev {
        required = "conf";
        algo = "sha256,rsa2048";
        rsa,num-bits = <0x800>;
        rsa,modulus = [ ... ];
        ...
    };
    key-iotgw-fit-yk-2026 {
        required = "conf";
        algo = "sha256,rsa2048";
        rsa,num-bits = <0x800>;
        rsa,modulus = [ ... ];
        ...
    };
};
```

Both `key-*` subnodes present, `required-mode = "any"`. If
`required-mode` is missing or set to `"all"` and both keys are
`required = "conf"`, a FIT signed by only one key will be rejected at
boot.

### On-target verification

After flashing Image B and booting:

```bash
# Confirm both trust roots are live in U-Boot's control FDT.
nsenter -t 1 -m cat /sys/firmware/devicetree/base/signature/required-mode
nsenter -t 1 -m ls /sys/firmware/devicetree/base/signature/
```

Expected: `any` on stdout, and two `key-*` directories.

Test both signing paths sequentially:

1. **File-key-signed FIT path** — flash the Image B build, boot, check
   U-Boot log for FIT verification success against
   `key-${UBOOT_SIGN_KEYNAME}`. Normal `iotgw-rauc-install` flow works
   as it did pre-rotation.
2. **YK-signed FIT path** — run `make sign-bootfiles-fit-yk` against the
   same build to swap the inner FIT signature to slot 9a (see the next
   section), reassemble the bundle, install on the device that booted
   step 1, reboot. U-Boot must accept the FIT against
   `key-iotgw-fit-yk-2026`.

Both paths must boot cleanly on the same device before promoting Image
B to fleet rollout, and before scoping Image C.

### Cutover (Image C, separate PR)

Image C drops `IOTGW_FIT_TRUST_FILE_KEY = "0"` in `kas/local.yml`. The
recipe then injects only the YK pubkey; `required-mode = "any"` is
still set (harmless with one key). The bundle FIT MUST be HSM-signed
before release; a file-key-signed FIT would be rejected by every
fielded Image C device. Image C is scoped to a separate PR after
Image B is validated on hardware.

## Signing FIT against a PKCS#11 token (YubiKey)

The default flow above signs the FIT inside bitbake against a file-based
RSA key under `UBOOT_SIGN_KEYDIR`. The HSM-backed flow moves the FIT
signing key to a PKCS#11 token (the YubiKey PIV slot 9a in this
repository's example, RSA-2048) and performs the signing as a
**post-build** step. The bitbake-side signer stays file-based; only the
deploy artifact is re-signed.

### Why not sign inside bitbake

Two interacting mkimage bugs make in-bitbake PKCS#11 signing
unworkable as of u-boot-tools-native 2025.04:

1. **URI synthesis from `-k` is malformed.** When `mkimage` is given
   both `-k <keydir>` and `-N pkcs11`, it synthesises a non-RFC-7512
   PKCS#11 URI of the form `pkcs11:<keydir>;object=<hint>;type=private`.
   `engine_pkcs11` rejects it.
2. **`-G` is ignored when `-k` is present.** `lib/rsa/rsa-sign.c`
   prioritises the keydir path. Both upstream
   `kernel-fitimage.bbclass` and this project's
   `iotgw-fit-custom-its.bbclass` hardcode `-k`, and
   `UBOOT_MKIMAGE_SIGN_ARGS` is appended *after* `-k`, so a
   `kas/local.yml`-level override cannot reach the working `-G` path.

There is also a silent no-op trap in the no-`-k` path:
`mkimage -F -N pkcs11 <fit>` without `-k` **and** without `-G` exits 0,
regenerates hashes, repacks the FDT, and leaves the original signature
bytes untouched. The `sign-fit.sh` wrapper guards against this by
requiring at least one `Signature written` line in mkimage's captured
output before declaring success.

Upstream migration note: the meta-oe `fitimage.bbclass` merged
post-Scarthgap provides native PKCS#11 FIT signing support and is the
intended migration target once this project moves beyond its current
Scarthgap layer set.

### How `scripts/sign-fit.sh` works

The wrapper does three things, in order:

1. **`fdtput` rewrite** — walks every
   `/configurations/conf-*/signature*/key-name-hint` and sets it to the
   project-controlled hint (default `iotgw-fit-yk-2026`, override with
   `--key-name-hint`). This hint must match the
   `/signature/key-<hint>` node injected into U-Boot's control FDT by
   the kernel-fit recipe — devices reject FITs whose hint doesn't
   resolve to a trusted key. It also drives the resulting `Sign algo:`
   audit line. It is **not** the key-lookup mechanism for signing.
2. **`mkimage -F -N pkcs11 -G "<uri>" <fit>`** — signs in place via
   `engine_pkcs11` against `libykcs11`. The PKCS#11 URI passed via
   `-G` is the actual lookup mechanism. Default URI is
   `pkcs11:id=%01;type=private`, which selects PIV slot 9a by PKCS#11
   ID (libykcs11 maps slot 9a to ID 01). Override `--uri` for
   token-anchored URIs in multi-YubiKey setups, e.g.
   `pkcs11:token=YubiKey%20PIV%20%23<SERIAL>;id=%01;type=private`.
   PIN is prompted on the terminal; touch is required per slot 9a's
   touch policy (`CACHED` covers a multi-config signing call with one
   tap).
3. **Success detection + structural verify** — captures mkimage's
   output; requires at least one `Signature written` log line.
   Deterministic RSA-PKCS#1 v1.5 over the FIT signed range makes
   byte-comparison guards unreliable (re-signing the same content
   with the same key produces identical bytes), so the log line is
   the authoritative success signal. The optional `--verify` is a
   *structural* check on top: it asserts every signature node
   carries `Sign algo: sha256,rsa2048:<KEY_NAME_HINT>` and a non-empty
   `Sign value`. It does **not** cryptographically verify the
   signature against the slot's public key — for that, run
   `mkimage -V` against a DTB that embeds the expected pubkey.

The script mutates `--fit` in place. Run it against a copy of the
deploy artifact:

```bash
cp build/tmp-glibc/.../fitImage /tmp/fit-test/fitImage.yk
bash scripts/sign-fit.sh --fit /tmp/fit-test/fitImage.yk --verify
```

### What success looks like

On a YubiKey-signed fitImage, `dumpimage -l` shows, for every
configuration:

```
Sign algo:    sha256,rsa2048:iotgw-fit-yk-2026
Sign value:   <256 bytes of fresh RSA-2048 signature>
Timestamp:    <signing time, not build time>
```

Compared against the file-signed source, the configurations'
`Sign value` bytes are entirely different and the `Timestamp` is the
post-build signing wall clock. Both keys produce 256-byte RSA-2048
signatures over the same hash, so byte-length is identical — only the
content differs.

For release evidence, capture `dumpimage -l` output and SHA-256 hashes
for the source and HSM-signed FIT artifacts in the release record.

For bundle-side evidence, extract the final `.raucb` with RAUC itself
instead of raw `unsquashfs` (encrypted verity bundles are not directly
readable as SquashFS):

```bash
DEPLOY=build/tmp-glibc/deploy/images/raspberrypi5
OUT=/tmp/iotgw-fit-bundle-check

rm -rf "$OUT"
rauc extract \
  --trust-environment \
  --keyring=/path/to/root-ca-primary.crt \
  --key=/path/to/device-decryption.key \
  "$DEPLOY/iot-gw-image-dev-bundle-full-fit.raucb" \
  "$OUT"

mkdir -p "$OUT/bootfiles"
tar -xzf "$OUT/bootfiles-fit.tar.gz" -C "$OUT/bootfiles"
sha256sum "$OUT/bootfiles-fit.tar.gz" "$DEPLOY/bootfiles-fit.tar.gz"
dumpimage -l "$OUT/bootfiles/fitImage" | \
  grep -E 'Sign algo:|Sign value:|Timestamp:'
```

### Detached signing — three independent stages

HSM signing must never sit on the critical path of an unattended build.
A CI runner or any pipeline that needs to complete without operator
intervention has to be able to produce *something* releasable without
contacting a YubiKey. The signing step is a separate ceremony — run on
a machine with the HSM physically attached, by an operator who is
present, or by a hardened signing daemon — and its output is fed back
into a final assembly step.

This repo expresses the model as three independent Make targets, none
of them prerequisites of the others:

```mermaid
flowchart TD
    subgraph BuildPhase["Build phase (unattended build runner)"]
        A["make bundle-dev-full-fit"]
        B["bootfiles-fit.tar.gz<br/>inner FIT signed by file key"]
        C["candidate .raucb<br/>not final release if HSM signing is required"]
        A --> B
        A --> C
    end

    subgraph Store1["Release artifact storage"]
        D["file-key signed build artifacts"]
    end

    subgraph SignPhase["Sign phase (operator workstation or signing server)"]
        E["make sign-bootfiles-fit-yk"]
        F["scripts/sign-bootfiles-fit.sh"]
        G["scripts/sign-fit.sh"]
        YK["PKCS#11 token<br/>RSA-2048 private key<br/>non-extractable"]
        H["bootfiles-fit.tar.gz<br/>inner FIT HSM-signed"]
        E --> F --> G
        G -->|"PKCS#11 via engine_pkcs11<br/>PIN + touch or signing-daemon policy"| YK
        YK --> G --> H
    end

    subgraph Store2["Release artifact storage"]
        I["HSM-signed bootfiles-fit.tar.gz"]
    end

    subgraph AssemblePhase["Assemble phase (unattended bundle assembly)"]
        J["make bundle-dev-full-fit-resign"]
        K["iot-gw-bundle-full-fit<br/>do_configure re-copies signed tarball"]
        L["final .raucb<br/>contains HSM-signed FIT"]
        J --> K --> L
    end

    B --> D --> E
    H --> I --> J
```

The same trust boundary can be viewed as artifact movement:

```mermaid
sequenceDiagram
    autonumber
    participant CI as CI/build runner
    participant Store as Artifact storage
    participant Signer as Operator or signing service
    participant YK as YubiKey/HSM
    participant Final as Final assembly runner

    CI->>CI: make bundle-dev-full-fit
    CI->>Store: publish bootfiles-fit.tar.gz and candidate .raucb
    Store->>Signer: fetch bootfiles-fit.tar.gz
    Signer->>YK: PKCS#11 sign FIT hashes<br/>PIN/touch or daemon policy
    YK-->>Signer: RSA-2048 signatures
    Signer->>Store: publish HSM-signed bootfiles-fit.tar.gz
    Store->>Final: fetch signed tarball
    Final->>Final: make bundle-dev-full-fit-resign
    Final->>Store: publish final HSM-signed .raucb
```

#### Build — `make bundle-dev-full-fit` (unattended)

Same target as the file-key flow above. No HSM, no PIN, no touch.
Suitable for GitHub Actions, GitLab runners, or any unattended
pipeline. Produces the file-key-signed `.raucb` plus the deploy
`bootfiles-fit.tar.gz` whose inner FIT is file-key signed.

#### Sign — `make sign-bootfiles-fit-yk` (operator-only)

Wraps `scripts/sign-bootfiles-fit.sh`. Extracts
`deploy/.../bootfiles-fit.tar.gz`, calls `sign-fit.sh` on the inner
FIT (prompts for PIN, requires touch when the slot policy demands
one), repacks the tarball in place. Snapshot/restore semantics: if
anything fails between extract and repack, the original tarball is
restored from a `.bak` sibling.

The wrapper is idempotent. Before extracting and re-signing, it peeks
at the inner `fitImage`'s `Sign algo:` audit lines; if **every**
signature node already advertises the HSM key-name-hint
(`sha256,rsa2048:<KEY_NAME_HINT>`), the wrapper exits cleanly without
contacting the token. A fresh build produces a file-key-signed FIT, so
the audit line shows the file-key label and the wrapper signs. A
partially labelled FIT (one config matches, another still shows the
file-key label) is NOT skipped — the wrapper logs the mismatch and
re-signs all nodes, so a mixed-trust tarball never makes it to the
bundle. To override the skip and re-sign anyway, pass `--force` to the
wrapper. With the Make wrapper:

```bash
make sign-bootfiles-fit-yk SIGN_BOOTFILES_ARGS=--force
```

`SIGN_BOOTFILES_ARGS` is consumed by `sign-bootfiles-fit.sh` before
the `--` separator; `SIGN_FIT_ARGS` is forwarded to `sign-fit.sh`
after `--`.

The check is content-based: the "already labelled" signal lives
inside the artifact, not in a sidecar file. The same archive can be
moved between machines (CI → operator workstation → final-assembly
runner) and the idempotency decision is consistent everywhere. The
check inspects audit metadata (the key-name-hint embedded in each
`signature*` node), not the cryptographic signature. The
authoritative signature verification still belongs to U-Boot at boot
time, against the public key embedded in the signing DTB.

Runs **only** on a machine with the HSM physically attached — an
operator workstation or a hardened signing server. Never runs in CI.
The signing step is bounded in time and well-defined: one PIN entry,
one touch (CACHED covers all configurations in the FIT), seconds of
wall clock.

#### Assemble — `make bundle-dev-full-fit-resign` (unattended)

`bitbake -C do_configure iot-gw-bundle-full-fit`. Invalidates the
bundle recipe's `do_configure` stamp so it re-copies the now-HSM-
signed tarball from DEPLOY_DIR_IMAGE into its WORKDIR and re-runs
`do_bundle`. A few minutes; no kernel/rootfs rebuild. Can run in CI
on any runner that has the signed tarball deployed (e.g. via an
artifact pull from release storage), or locally by the operator
right after the sign phase.

#### CI / signing-server integration

For pipelines that have to be fully unattended, the only options are:

1. **Detached signing server** — a small daemon on a controlled host
   with the HSM permanently attached. It receives a signing request
   (artifact + metadata) over an authenticated channel (mTLS), runs
   the equivalent of the sign phase, returns the signed artifact.
   The PIN is pre-loaded into the daemon's session at start-up
   (operator authenticates once); touch can be CACHED with a long
   window or NEVER (lower-assurance only). The CI runner then runs
   the assemble phase.
2. **Manual handoff** — CI runs the build phase and publishes
   artifacts; a release manager pulls them to a workstation with the
   token attached, runs the sign phase, publishes the signed tarball
   back; a final CI job (or the operator) runs the assemble phase.

The repository ships only the building blocks (`sign-fit.sh`,
`sign-bootfiles-fit.sh`, the three Make targets). The signing daemon
is intentionally out of scope here — it belongs to whichever signing
infrastructure consumes this layer.

The example token policy in this repository is touch `CACHED` + PIN
`ALWAYS`, which prevents headless unattended HSM signing unless a
project explicitly chooses a relaxed signing-server policy.

### Slot 9a provisioning reference

Provision slot 9a with an RSA-2048 private key generated on-device,
create or import the matching public certificate used for U-Boot FIT
verification, and capture the YubiKey F9 attestation certificate in the
release key-management record. Private-key material must never be
exported or committed. Local engine/provider configuration and
certificates are expected to live outside the repository, for example
under an operator-controlled key directory.
