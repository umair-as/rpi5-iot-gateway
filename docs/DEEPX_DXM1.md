# DEEPX DX-M1 AI Accelerator

PCIe NPU (M.2, 25 TOPS) on the Raspberry Pi 5 external FFC connector through
an M.2 carrier. The driver, DX-RT runtime, and demo assets come from the
upstream `meta-deepx-m1` layer; project-specific integration remains in
`meta-iot-gateway`.

**Status: hardware- and OTA-validated development integration.** A clean image
built entirely from repository metadata, installed with the dedicated full-FIT
bundle, completes real DX-M1 inference, passes the acceptance suite with zero
failures, shows non-zero NPU utilization, and needs no target-side hand edits.
Production-key, firmware-delivery and model-lifecycle work remain open; see
[Delivery and production status](#7-delivery-and-production-status).

---

## 1. Build and bundle

```bash
make dev                      # or: make base, make desktop
make bundle-dev-full-fit      # or: make bundle-desktop-full-fit
```

The card is part of the platform, so every non-prod target carries the stack.
`base`, `dev` and their bundles compose `kas/deepx.yml` (the Makefile's
`IMAGE_KAS`), and `kas/desktop.yml` includes it. The overlay makes
`meta-deepx-m1` available and sets `IOTGW_ENABLE_DEEPX_DXM1=1`. Base and dev get
the driver and runtime; the desktop adds the demo stack. Prod composes neither
until the module-signing key is protected (§7).

Bundles are deliberately `full-fit`: they carry the matching slot FITs
(kernel, device tree and command line) alongside the rootfs, so the modules
always arrive with the kernel that trusts their signing key.

The image targets clean `make-mod-scripts` before building. dev, desktop and
prod kernels differ but share the `kernel-build-artifacts` tree, and after a
build in another composition its stale stamp otherwise breaks `dx-driver` with
`No rule to make target 'modules'`.

Do not hand-roll raw `kas`/BitBake commands for this path. The Makefile carries
the environment-passthrough wiring, bundle image selection, and overlay
composition that otherwise fail silently.

### Two gates, deliberately separate

| Gate | Mechanism | Effect |
|---|---|---|
| Layer availability | compose `kas/deepx.yml` | `meta-deepx-m1` parses |
| Feature enablement | `IOTGW_ENABLE_DEEPX_DXM1` (distro default `0`, `kas/deepx.yml` sets `1` weakly) | ksyms trim disabled (`deepx-dxm1-ksyms.cfg`), `pcie_aspm=off`, packages installed |

The layer alone puts nothing into an image. `IOTGW_ENABLE_DEEPX_DXM1=0 make dev`
leaves the layer present but disables the feature. Enabling the feature
without the layer fails during parsing with a message that names the targets
that compose it.

## 2. Validated configuration

Every fix comes from repository metadata and the matching full-FIT bundle:

| Component | Validated state |
|---|---|
| Accelerator firmware | DX-M1 firmware `v2.7.4`, stored on the card |
| Driver source/package | DX driver `v2.6.0`; PCIe component reports `v2.5.0` |
| Runtime | DX-RT `v3.4.1` in the Yocto image |
| PCIe | Gen2 x1, `Mem+ BusMaster+`, ASPM disabled, AER status clear |
| Runtime result | `/dev/dxrt0` present; `dxrtd` active as user `dxrt` |
| Inference | `YoloV5S_PPU.dxnn`; non-zero utilization on all three NPU cores |
| Boot/update | slot-specific `fitImage-b`; `pcie_aspm=off`; `rauc.slot=B` |
| Acceptance | zero FAIL after a full-FIT RAUC install |

On the desktop image the DX-M1 domains are enforcing. The administrator
console has no access to the accelerator or the compositor by design, so
section 7 runs device status and the timed inference through
`iotgw-dx-probe.service`, the launcher binary in its own domain
(`iotgw_dxdemo_t`), and reads the result from the journal. The CPU-fallback
discriminator is the accelerator's DMA interrupt (`dx-dma_0` in
`/proc/interrupts`): no interrupt during the run means it did not reach the NPU.
On an image without the launcher (headless dev), section 7 falls back to the
administrator-shell path with `dxtop`, which needs the domain permissive.

Observed sample rates vary substantially with the model and output pipeline and
must not be presented as a general DX-M1 benchmark.

Run the reusable acceptance check from the build host:

```bash
IOTGW_REMOTE_ENV="IOTGW_DXM1_EXPECT_VERMAGIC=<built-kernel-release> \
IOTGW_DXM1_EXPECT_SIG_KEY=<complete-module-key-fingerprint>" \
  scripts/run-target-checks.sh <device-address> deepx-acceptance
```

The expected release and signing-key fingerprint must come from the artifact
being tested. Kernel/module self-consistency cannot detect a stale but
internally consistent SD card.

## 3. Firmware is separate from the SD image

DX-M1 firmware lives on the accelerator, not on the Raspberry Pi SD card.
Firmware `v2.7.4` therefore survives power cycles and SD-card/image swaps. A
fresh Yocto image uses the firmware already stored on the card.

Vendor DX-RT `v3.4.2` refused inference with the original firmware `v2.1.5`
and explicitly required `v2.7.0` or newer. This image's DX-RT `v3.4.1` is
validated with `v2.7.4`; its exact lower bound was not independently measured.
This layer currently ships neither the firmware payload nor an updater.
Firmware was upgraded using DEEPX's supported tooling on a known-good Debian
installation, followed by a full power cycle. Do not treat reflashing the
Yocto image as a firmware update.

## 4. What gets installed

`packagegroup-iot-gw-deepx` provides the modules, runtime, and project glue:

- `dx-driver` — the out-of-tree kernel modules (`dx_dma`, `dxrt_driver`)
- `dx-rt` — the runtime and all its tools: `dxrtd`, `dxrt-cli`, `run_model`,
  `dxtop`, `dxbenchmark`
- `iotgw-deepx-runtime` — service account, device policy, and systemd unit

There is deliberately **no** dependency on `dx-rt-cli` or `dx-rt-examples`.
Upstream declares them with `PACKAGES:append` at a point where the package
split has already been computed, so neither package is ever emitted; depending
on them fails with `nothing provides dx-rt-examples`. Every tool listed above
ships inside `dx-rt` itself.

`packagegroup-iot-gw-deepx-demo` adds `dx-stream` — the GStreamer elements
`dxpreprocess`, `dxinfer`, `dxpostprocess` and `dxosd` — together with
`dx-stream-sample`, which carries the precompiled `YoloV5S_PPU.dxnn` and an
H.264 payload. It is separate so a production profile can take the runtime
without the demo payload. `iot-gw-image-base.inc` installs the base group into
every image built with the feature on; the desktop adds `-demo`.

## 5. PCIe, driver loading, and runtime policy

**Host controller.** `CONFIG_PCIE_BRCMSTB=y` builds the BCM2712 PCIe host
controller into the kernel. The external bus therefore exists before
userspace, eliminating a class of boot-order races for any PCIe endpoint.

**Endpoint driver.** There is deliberately no `KERNEL_MODULE_AUTOLOAD` entry
for `dx_dma`. Forced early loading lets `dxrt_driver` initialize before the
PCIe endpoint exists; it finds zero devices and never rescans.
The working path is event-driven:

```text
BCM2712 host bridge enumerates DX-M1
        → PCI modalias loads dx_dma
        → dx_dma probes the endpoint
        → softdep post: loads dxrt_driver
        → dxrt_driver_cdev_init: 1 devices
```

**Raspberry Pi MSI mode.** The upstream driver enables its BCM2712-specific
single-MSI path only when `CONFIG_RPI_BUILD` reaches Kbuild. Its path-name
heuristic does not match a Yocto work directory, so the bbappend passes the
make variable explicitly. The built `dx_dma.ko` must contain
`RPi: forcing single MSI mode`; setting a variable without checking the object
is not evidence.

**ASPM.** DX-M1 images add `pcie_aspm=off`. With ASPM enabled, the endpoint
repeatedly appeared to reset, accumulated correctable PCIe errors, and the
driver health worker's config-space read could trigger a fatal BCM2712 SError.
Disabling ASPM reduced resets and AER errors to zero in a single-variable
on-target test. The argument is global and also disables power management on
the RP1 link; it is scoped to DX-M1 images until a tested device-specific L1
quirk exists.

**Device ownership.** `/dev/dxrt*` is `root:dxrt 0660`, replacing upstream's
world-writable `0666` rule. `dxrtd.service` runs as the dedicated `dxrt` user
and starts only when a device node exists. `PrivateDevices` is deliberately
not enabled because it would hide the accelerator from the service.

## 6. Kernel symbols and module signing

The real driver `v2.6.0` source is pinned explicitly. The upstream recipe named
`2.6.0` pointed at an older commit whose module reported `2.2.0`; the project
bbappend corrects that source/version mismatch.

`CONFIG_TRIM_UNUSED_KSYMS=y` (from `security-prod.cfg`) strips exports unused
by in-tree modules, and the out-of-tree `dx_dma.ko` is invisible to it. Images
with the accelerator therefore turn the trim off: the `igw_deepx_dxm1` feature
adds `deepx-dxm1-ksyms.cfg`, merged last so it wins over `security-prod.cfg`.
Images without the accelerator, prod included, keep the trim. A symbol
allowlist (`CONFIG_UNUSED_KSYMS_WHITELIST`) is not used: it breaks on every
driver re-pin and on every kernel-surface change that removes an in-tree user
of a symbol the driver needs; module signing, below, is the barrier against
foreign modules.

Modules are signed by Kbuild through `CONFIG_MODULE_SIG_ALL=y` during
`modules_install`. `iotgw-kernel-module-signing.bbclass` verifies the exact
signature trailer and fails the build if it is missing. Do not add a second
signer.

The kernel enforces signatures with `CONFIG_MODULE_SIG_FORCE=y`. A module signed
by a key the kernel does not trust is rejected with `EKEYREJECTED`, even when
vermagic is unchanged.

Whether a kernel rebuild breaks that trust depends on the signing key in use:

- **Default (no operator key).** `CONFIG_MODULE_SIG_KEY` keeps its upstream
  value and Kbuild auto-generates a throwaway keypair per kernel build, so
  modules from build *N* cannot load on build *N+1*. Kernel and modules are an
  inseparable pair, and acceptance needs the fingerprint re-recorded each build.
- **With `IOTGW_MODULE_SIG_KEY_FILE` set.** The kernel trusts a persistent
  operator key, the fingerprint is stable across rebuilds, and kernel and
  modules become independently rebuildable. See `docs/KERNEL.md`, "Persistent
  module-signing key".

Every bundle carries the bootfiles archive and both slot FITs
(`IOTGW_RAUC_UPDATE_BOOTFILES = "1"`; the assembly gate fails without it), and
under dm-verity a rootfs without its matching slot FIT cannot boot, so a
rootfs-only update that moves modules is not possible.

## 7. Delivery and production status

The validated state is suitable for development and demos. These items remain
before calling it production-complete:

- **Production protection for the module-signing key.** The persistent-key
  mechanism works and is validated, but the key it uses is a plain file on the
  build host with no hardware protection — appropriate for development and lab
  images, not for production. It belongs in the same HSM/YubiKey handling as
  the FIT signing key (`docs/FIT_BOOT_SIGNING.md`).
- **Firmware delivery and recovery.** Firmware `v2.7.4` is on the tested card,
  but the distro has no firmware payload, updater, rollback, or fleet policy.
- **Signed model delivery/model OTA.** The demo model is a build-time vendor
  asset, not a production model lifecycle.

The OTA paths are `make bundle-dev-full-fit` and, for the desktop image,
`make bundle-desktop-full-fit`. Each carries the rootfs and slot-specific FIT
boot assets together. The acceptance gate compares the complete module
signing-key fingerprint because vermagic stays identical across builds with
different generated keys.

## 8. Using the vendor suite alongside this image

The image pins specific DEEPX component versions. A `dx-all-suite` checkout on
the workstation will usually be **newer**, and the two are not interchangeable:

| Component  | This image | Suite checkout |
|------------|------------|----------------|
| dx-driver  | 2.6.0      | 2.6.0          |
| Firmware   | 2.7.4      | 2.7.4          |
| DX-RT      | 3.4.1      | 3.4.2          |
| DX-Stream  | 3.1.1      | 3.1.2          |
| DX-App     | not packaged | 3.2.2        |

What can be taken from a suite checkout as **copyable candidate assets** —
copying is the easy part, and compatibility must be validated on the target in
every case below:

- **Precompiled `.dxnn` models.** These are NPU bytecode produced by
  dx-compiler, not aarch64 code, so no cross-compilation is involved. That is
  not the same as guaranteed to run: a model exported by a newer dx-compiler
  may assume runtime behaviour this image's DX-RT does not have, and a model is
  only useful with a postprocess library that matches its output tensors.
  Validate each one with `run_model` before building a pipeline around it.
- **Shell/JSON GStreamer pipelines** built on the installed elements, and the
  video/data assets beside them. `/usr/local/share/gstdxstream` is symlinked to
  `${datadir}/gstdxstream` so the vendor's hardcoded Debian prefix resolves —
  which makes them path-compatible, not verified.
- **DX-Stream 3.1.1-era demonstrations**, where the element set matches. Newer
  ones need checking against the list below.

What does **not** work by copying:

- **Pipelines needing a postprocess library the image does not ship.** The
  3.1.2 depth-estimation pipeline needs `yolo26_depth`, which is not among the
  15 libraries in `${datadir}/gstdxstream/lib` on a 3.1.1 image. Check for the
  library before assuming a newer pipeline runs.
- **DX-App C++ programs.** They need a recipe or an SDK cross-build; see
  `.claude/rules/cross-compilation.md`.
- **Python showcase apps, PaddleOCR, RapidDoc, the mini-games, AI Studio.**
  These need `dx_engine`, OpenCV, NumPy, Ultralytics and per-application Python
  dependencies that this image does not carry.
- **Compiler, export and model-training workflows.** Keep these on the x86-64
  host and deploy only the resulting `.dxnn`.

Staging any of this onto the target is a manual step and deliberately not
automated here. `/data` is the right destination — it is shared across both A/B
slots and therefore survives an OTA — but note that the showcase tree contains
several distinct models sharing the basename `yolo26n.dxnn`, so a copy that
flattens the directory structure will silently discard all but one. Preserve the
per-experiment directories.

> **Never run the vendor's Debian/Ubuntu `install.sh` on the target.** It would
> overwrite the layer-managed runtime, the signed kernel modules, the device
> policy and the service unit, none of which it knows about. Supporting a newer
> suite is a version-bump of the DX-RT and DX-Stream recipes followed by
> deliberate packaging of individual applications — not a bulk copy of the
> checkout onto the device.

## 9. Licensing

Every DEEPX package is `LICENSE = "Proprietary"` under a customer-only
licence: software is supplied to customers with a DEEPX NPU, and sharing is
prohibited. `MODULE_LICENSE("GPL")` in the driver governs kernel-symbol
eligibility; it does not change the recipe's legal licence.

Nothing proprietary is committed to this repository. Vendor source and demo
assets live in the pinned upstream layer under `.kas/` (gitignored).

> **An image or bundle built with this feature must not be redistributed.**

## 10. Hardware notes

- The Pi 5 external PCIe connector is x1, while the DX-M1 endpoint advertises
  x4 capability. Negotiating x1 is expected and cannot be fixed in software.
- The validated configuration is Gen2 (5 GT/s). Gen3 is an uncertified signal-
  integrity experiment on Raspberry Pi 5 and must be tested separately from
  correctness. The device tree is signed into the slot FIT, so a `config.txt`
  `dtparam=pciex1_gen=3` override does not reach the kernel; changing speed
  requires a DTS change.
- A `[virtual]` BAR in `lspci` means Linux reports a resource while the device
  BAR itself reads zero. It is worth recording, but successful inference shows
  it is not by itself proof of a missing required feature.
- A TPM on the GPIO header may physically conflict with an accelerator carrier.

## See also

- [AI_ACCELERATION_101.md](AI_ACCELERATION_101.md) — NPU vocabulary and the
  host/target model
- [AI_ACCELERATION_ARCHITECTURE.md](AI_ACCELERATION_ARCHITECTURE.md) — the
  illustrated build-to-inference pipeline
- [FIT_BOOT_SIGNING.md](FIT_BOOT_SIGNING.md) — FIT signing and matched boot
  assets
- [OPERATIONS.md](OPERATIONS.md) — flashing, provisioning, and target access
