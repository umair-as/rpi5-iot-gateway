<div align="center">

#  IoT Gateway OS for Raspberry Pi 5

**A Yocto-based Linux distribution for IoT gateway applications**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-Scarthgap-orange.svg)](https://www.yoctoproject.org/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%205-c51a4a.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![RAUC](https://img.shields.io/badge/OTA-RAUC-green.svg)](https://rauc.io/)

</div>

---

## 📋 Overview

A **hardened, embedded Linux distribution** for IoT gateway deployments on Raspberry Pi 5. Built on Yocto Project with KAS tooling.

**Key Features:**
- 🔄 **A/B OTA Updates** — Rootfs A/B updates with RAUC slot rollback semantics (enabled by default)
- 🔒 **Security Hardened** — KSPP-aligned kernel, compiler flags, runtime hardening
- 📦 **Container Runtime** — Podman, Buildah, and Skopeo for containerized workloads
- 🛠️ **Developer-Friendly** — Tooling for debugging and development

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
# Edit kas/local.yml - set RAUC key paths and WiFi credentials

# Build images (using Makefile - recommended)
make dev         # Development image
make prod        # Production image
make bundle-dev-full   # OTA bundle with kernel

# OR using KAS directly
kas build kas/local.yml --target iot-gw-image-dev
kas build kas/local.yml --target iot-gw-image-prod
kas build kas/local.yml --target iot-gw-bundle-full
```

### Flash to SD Card

```bash
sudo bmaptool copy \
  build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.bz2 \
  /dev/sdX
```

### Default Accounts

Default users: `root`, `devel`.
Override at build time with hashed passwords in `kas/local.yml` or `build/conf/local.conf`:

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

```bash
# 1. Copy bundle to device
scp build/tmp/deploy/images/raspberrypi5/iot-gw-bundle-full.raucb root@<device-ip>:/tmp/

# 2. Install via project wrapper (handles preflight/cert checks)
iotgw-rauc-install /tmp/iot-gw-bundle-full.raucb
reboot

# 3. Verify after reboot
rauc status
```

### Generate RAUC Signing Keys

> ⚠️ **Required**: Generate your own keys before building bundles!

```bash
# Generate keys
./meta-iot-gateway/scripts/generate-rauc-certs.sh

# Move to secure location
mkdir -p ~/rauc-keys
mv dev-key.pem dev-cert.pem ca.cert.pem ~/rauc-keys/

# Configure in kas/local.yml
# Set IOTGW_RAUC_KEY_DIR to ~/rauc-keys
```

See `kas/local.yml.example` for configuration template.

---

## 📦 Image Variants

| Image | Purpose | Includes | Size |
|-------|---------|----------|------|
| `iot-gw-image-base` | Minimal production | Core system, RAUC | Small |
| `iot-gw-image-dev` | Development | +Debug tools, compilers | Medium |
| `iot-gw-image-prod` | Production | Lean runtime, hardened | Minimal |

Build commands:
```bash
make dev       # or kas build kas/local.yml --target iot-gw-image-dev
make prod      # or kas build kas/local.yml --target iot-gw-image-prod
```

Partitioning details and WKS variants are documented in [Partition Layouts](docs/PARTITIONS.md).

---

## 🎨 Customization

Use these docs to customize the gateway image and runtime behavior:

- [Operations](docs/OPERATIONS.md) for host build workflow, provisioning, and OTA runtime operations
- [Partition Layouts](docs/PARTITIONS.md) for storage sizing and WKS selection

Subsystem deep dives:

- [Kernel Configuration](docs/KERNEL.md)
- [OpenThread Border Router](docs/OTBR.md)

---

## 🛠️ Common Tasks

For practical runbooks and command workflows:

- Build, flash, and OTA validation: [Operations](docs/OPERATIONS.md)
- RAUC update lifecycle checks: [RAUC Update Runbook](docs/RAUC_UPDATE.md)
- Overlay drift-control behavior after updates: [Overlay Reconciliation](docs/OVERLAY_RECONCILIATION.md)

---

## 📚 Documentation

Detailed documentation is available in the `docs/` directory:

- **[Operations](docs/OPERATIONS.md)** — Host build, networking, dev SSH keys, OTA runtime workflows
- **[Security Hardening](docs/SECURITY.md)** — Kernel hardening, compiler flags, audit framework, validation
- **[Kernel Configuration](docs/KERNEL.md)** — Feature sets, fragments, runtime parameters
- **[Partition Layouts](docs/PARTITIONS.md)** — RAUC A/B partitions, WKS variants, sizing
- **[OpenThread Border Router](docs/OTBR.md)** — OTBR setup, configuration, commissioning
- **[OTA Updates](docs/OTA_UPDATE.md)** — RAUC workflow, bundles, rollback
- **[RAUC Update Runbook](docs/RAUC_UPDATE.md)** — Slot validation and adaptive update checks
- **[FIT Boot and Signing](docs/FIT_BOOT_SIGNING.md)** — FIT flow, signing setup, and verification workflow
- **[Overlay Reconciliation](docs/OVERLAY_RECONCILIATION.md)** — `/etc` drift-control architecture, policy model, and OTA tradeoffs

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
