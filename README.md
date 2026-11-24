<div align="center">

#  IoT Gateway OS for Raspberry Pi 5

**A Yocto-based Linux distribution for IoT gateway applications**

[![release-hygiene](https://github.com/umair-as/rpi5-iot-gateway/actions/workflows/release-hygiene.yml/badge.svg?branch=main)](https://github.com/umair-as/rpi5-iot-gateway/actions/workflows/release-hygiene.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-wrynose-orange.svg)](https://www.yoctoproject.org/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%205-c51a4a.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![RAUC](https://img.shields.io/badge/OTA-RAUC-green.svg)](https://rauc.io/)

</div>

---

## 📋 Overview

A **hardened, embedded Linux distribution** for IoT gateway deployments on Raspberry Pi 5. Built on Yocto Project with KAS tooling.

**Key Features:**
- 🛡️ **SELinux enforcing on every image** — refpolicy-mcs plus a project policy module that confines the gateway daemons (OTBR, DX-M1 runtime and demo, Weston, OTA key access); no permissive domains, and prod builds refuse one
- 📦 **Containers, first-class** — rootless Podman in every image: dedicated service account, Quadlet units, `pasta` networking, seccomp, store under `/data`, workloads confined as `container_t`; Buildah/Skopeo opt-in (`IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=1`)
- 🔐 **Verified boot chain** — mandatory signed FIT, dm-verity root authenticated by the FIT
- 🔄 **A/B OTA Updates** — Rootfs A/B updates with RAUC slot rollback semantics (enabled by default)
- ⚡ **Hardware-validated AI acceleration** — DEEPX DX-M1 PCIe NPU stack with signed drivers and on-target inference checks, in every image but prod (yet)
- 🔒 **Security Hardened** — KSPP-aligned kernel, compiler flags, runtime hardening, SBOM and CVE triage
- 🛠️ **Developer-Friendly** — Tooling for debugging and development

---

## 🛡️ SELinux Enforcing

SELinux is the distro's mandatory access control, and every image boots
**enforcing**. The policy is refpolicy-mcs plus the project module
`iotgw.te`, which gives each long-running gateway service its own domain:
OTBR (`iotgw_otbr_t`), the DX-M1 runtime and demo (`iotgw_dxrtd_t`,
`iotgw_dxdemo_t`), Weston and the health daemon. RAUC runs in `rauc_t`; of
the confined domains only it may read the OTA device key (unconfined boot
domains such as `init_t` still can). Admins work in `sysadm_t` from the
console; SSH logins land in `staff_t` (dev and desktop root, the prod OTA
operator).

The shipped policy declares no permissive domain. The build checks that, and
a prod image fails to build if one appears. Dev and desktop release
candidates are validated on the board under enforcing (services, OTA install,
DX-M1 inference); prod has not yet been booted enforcing on hardware. Known
gaps are listed in [SELinux enforcing](docs/SELINUX_ENFORCING.md). AppArmor is
not used.

See [SELinux](docs/SELINUX.md) (concepts and the local wiring) and
[SELinux enforcing](docs/SELINUX_ENFORCING.md) (runtime trials, diagnosing
denials).

---

## 📦 Containers

Every image ships the Podman stack; there is no toggle. Workloads run
**rootless** as one dedicated principal (`iotgw-ctr`) from Quadlet units in
its systemd user manager. Containers get `pasta` networking, podman's default
seccomp profile, and a store on `/data` that survives A/B updates, and SELinux
confines each one as `container_t` with its own MCS category pair. The rootful
engine is installed for one-off administration only; no unit starts it.

See [Containers](docs/CONTAINERS.md) for the principal, engine configuration,
adding a workload, and the acceptance check.

---

## ⚡ DEEPX DX-M1 AI Acceleration

The DX-M1 stack has completed hardware acceptance on Raspberry Pi 5:
the signed PCIe driver binds automatically, DX-RT discovers all three NPU
cores, the unprivileged runtime starts, and the bundled YOLOv5s sample produces
non-zero NPU utilization during inference. The acceptance suite passes with
zero failures after a full-FIT RAUC install, with no target-side edits.

```bash
make dev                          # Flashable development image (DX-M1 stack included)
make bundle IMAGE=dev             # OTA bundle with matching rootfs + FIT boot assets
make desktop                      # Desktop lab image, always with DX-M1 + on-screen demo
make bundle IMAGE=desktop         # OTA bundle for the desktop lab image
```

The accelerator ships in the base, dev and desktop images (not prod yet) and
carries proprietary vendor software; images
built with it must not be redistributed. See the
[DX-M1 integration guide](docs/DEEPX_DXM1.md),
[AI acceleration primer](docs/AI_ACCELERATION_101.md), and
[pipeline architecture](docs/AI_ACCELERATION_ARCHITECTURE.md) for the verified
boundary, firmware requirements, acceptance command, and remaining production
work.

---

## 🚀 Quick Start

### Prerequisites

```bash
# Install KAS build tool
pip3 install kas
```

### Build Images

```bash
# Copy example config and edit with your keys/WiFi
cp kas/local.yml.example kas/local.yml
# Edit kas/local.yml - set the FIT signing key (mandatory), RAUC key paths and WiFi credentials

# Build images (using Makefile - recommended)
make dev         # Development image
make prod        # Production image
make bundle IMAGE=dev      # OTA bundle with signed FIT boot assets
```

### Flash to SD Card

```bash
# Full write (recommended, especially for previously used cards)
zstdcat build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.zst \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

# Fast path: sparse-aware copy, then drop any stale U-Boot env file
sudo bmaptool copy \
  build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.zst \
  /dev/sdX
sudo mount /dev/sdX2 /mnt && sudo rm -f /mnt/uboot.env && sudo umount /mnt
```

`bmaptool` alone skips unmapped regions, so a reused card can keep its old
U-Boot environment (`uboot.env` on the `ubootenv` partition, p2). Remove the
file — do NOT zero the partition: the vfat filesystem and its `ubootenv`
label must survive or the `/uboot-env` mount fails at boot.
See [Operations](docs/OPERATIONS.md).

### Default Accounts

Dev and desktop images: `root` and `devel` (sudo). Prod: no account has a
password, root cannot log in over the network, and the only login is the
key-only OTA operator `iotgw-ops` (key file set by
`IOTGW_PROD_OPS_AUTH_KEYS_FILE`; the prod build fails without it).
Dev and desktop passwords are set at build time with hashes in `kas/local.yml`:

```bash
IOTGW_ROOT_PASSWORD_HASH = "$6$<hash>"
IOTGW_DEVEL_PASSWORD_HASH = "$6$<hash>"
```

Generate hashes with `openssl passwd -6` or `mkpasswd -m sha-512`.
For dev builds, SSH key bake-in workflow is documented in [Operations](docs/OPERATIONS.md).

---

## 🔄 RAUC Over-The-Air Updates

RAUC is **enabled by default** in this distribution.

### Deploy an Update

Dev and desktop images, from an administrator shell (the serial console, or
`sudo` as `devel`; an SSH root login is `staff_t` and cannot run the wrapper):

```bash
# Install via the project wrapper (preflight, certificate and /boot checks)
iotgw-rauc-install <path-or-https-url>/iot-gw-image-dev-bundle-full-fit.raucb
reboot

# Verify after reboot
rauc status
```

Prod images have no administrator shell. The OTA operator account
(`iotgw-ops`, key-only) copies the bundle to `/data/ota-tmp/` and runs
`rauc install` there. See [Operations](docs/OPERATIONS.md) §5 and the
[RAUC Update Runbook](docs/RAUC_UPDATE.md).

### Generate RAUC Signing Keys

> ⚠️ **Required**: Generate your own keys before building bundles!

Bundles are signed by a leaf issued from a Root CA → intermediate chain; the
Root cert(s) form the device keyring. Set the chain up as described in
[RAUC PKI](docs/RAUC_PKI.md), then point `IOTGW_RAUC_KEY_DIR` in
`kas/local.yml` at it (template: `kas/local.yml.example`).
`meta-iot-gateway/scripts/generate-rauc-certs.sh` produces only the deprecated
flat single-cert flow.

---

## 📦 Image Variants

| Image | Purpose | Includes | Size |
|-------|---------|----------|------|
| `iot-gw-image-base` | Minimal base image | Core system, RAUC, DX-M1 stack | Small |
| `iot-gw-image-dev` | Development | +Debug tools, compilers | Medium |
| `iot-gw-image-prod` | Production | Lean runtime, hardened | Minimal |
| `iot-gw-image-desktop` | Lab/demo image (not hardened) | +Weston, DX-M1 accelerator and on-screen inference demo | Large |

Build commands:
```bash
make dev
make prod
```

Partitioning details and WKS variants are documented in [Partition Layouts](docs/PARTITIONS.md).

---

## 🎨 Customization

Use these docs to customize the gateway image and runtime behavior:

- [Operations](docs/OPERATIONS.md) for host build workflow, provisioning, and OTA runtime operations
- [Partition Layouts](docs/PARTITIONS.md) for storage sizing and WKS selection
- [Persistent State Architecture](docs/PERSISTENT_STATE.md) for writable/persistent state and what survives updates

Subsystem deep dives:

- [Kernel Configuration](docs/KERNEL.md)
- [OpenThread Border Router](docs/OTBR.md)

---

## 🛠️ Common Tasks

For practical runbooks and command workflows:

- Build, flash, and OTA validation: [Operations](docs/OPERATIONS.md)
- RAUC update lifecycle checks: [RAUC Update Runbook](docs/RAUC_UPDATE.md)

---

## 📚 Documentation

Detailed documentation is available in the `docs/` directory:

- **[Operations](docs/OPERATIONS.md)** — Host build, networking, dev SSH keys, OTA runtime workflows
- **[SELinux](docs/SELINUX.md)** — Active MAC: concept primer, local wiring, refpolicy-mcs
- **[SELinux enforcing](docs/SELINUX_ENFORCING.md)** — Enforcing on every image: runtime trials, findings
- **[Containers](docs/CONTAINERS.md)** — Rootless Podman: the service account, engine configuration, adding a workload, confinement
- **[Security Hardening](docs/SECURITY.md)** — Kernel hardening, compiler flags, audit framework, validation
- **[Threat Model](docs/THREAT_MODEL.md)** — Gateway-wide STRIDE threat model: threats and controls
- **[U-Boot Hardening](docs/UBOOT_HARDENING.md)** — U-Boot hardening architecture and design decisions
- **[TPM Requirements](docs/TPM_REQUIREMENTS.md)** — Requirements and measured-boot design for Linux-side TPM use (SLB9672)
- **[SBOM and CVE scanning](docs/SBOM_CVE.md)** — Producing and reading the image SBOM and CVE report
- **[CVE applicability](docs/CVE_APPLICABILITY.md)** — Deciding whether a CVE applies, and what may suppress a finding
- **[Kernel CVE applicability](docs/KERNEL_CVE_APPLICABILITY.md)**, **[Kernel CVE patches](docs/KERNEL_CVE_PATCH.md)**, **[Kernel driver backports](docs/KERNEL_DRIVER_BACKPORT.md)** — Kernel-side triage and backport field guides
- **[Release process](docs/RELEASE.md)** — Tagging, deterministic release build, release notes and evidence
- **[Kernel Configuration](docs/KERNEL.md)** — Feature sets, fragments, build-time command line
- **[Partition Layouts](docs/PARTITIONS.md)** — RAUC A/B partitions, WKS variants, sizing
- **[Persistent State Architecture](docs/PERSISTENT_STATE.md)** — volatile `/var`, `/data`-backed persistent state, and what survives A/B updates
- **[OpenThread Border Router](docs/OTBR.md)** — OTBR setup, configuration, commissioning
- **[OTA Updates](docs/OTA_UPDATE.md)** — RAUC workflow, bundles, rollback
- **[RAUC Update Runbook](docs/RAUC_UPDATE.md)** — Install, slot validation and troubleshooting
- **[FIT Boot and Signing](docs/FIT_BOOT_SIGNING.md)** — FIT flow, signing setup, and verification workflow
- **[DEEPX DX-M1](docs/DEEPX_DXM1.md)** — Hardware-validated PCIe NPU integration, build/OTA commands, acceptance, and constraints
- **[AI Acceleration 101](docs/AI_ACCELERATION_101.md)** — NPU vocabulary and the host/target model pipeline
- **[AI Acceleration Architecture](docs/AI_ACCELERATION_ARCHITECTURE.md)** — Illustrated DX-M1 build-to-inference pipeline and reusable integration pattern

---

## 📚 References

| Resource | URL |
|----------|-----|
| Yocto Project | https://docs.yoctoproject.org |
| KAS Build Tool | https://kas.readthedocs.io |
| RAUC Framework | https://rauc.readthedocs.io |
| Raspberry Pi 5 | https://www.raspberrypi.com/documentation/ |

---

## 📄 License

**MIT License** — See [LICENSE](LICENSE) for details.

Individual components retain their respective licenses.
