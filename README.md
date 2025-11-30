<div align="center">

#  IoT Gateway OS for Raspberry Pi 5

**A production-ready Yocto-based Linux distribution for IoT gateway applications**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Yocto](https://img.shields.io/badge/Yocto-Scarthgap-orange.svg)](https://www.yoctoproject.org/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%205-c51a4a.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)
[![RAUC](https://img.shields.io/badge/OTA-RAUC-green.svg)](https://rauc.io/)

</div>

---

## 📋 Overview

A **hardened, embedded Linux distribution** for IoT gateway deployments on Raspberry Pi 5. Built on Yocto Project with KAS tooling.

**Key Features:**
- 🔄 **A/B OTA Updates** — Atomic updates with automatic rollback via RAUC (enabled by default)
- 🔒 **Security Hardened** — KSPP-aligned kernel, compiler flags, runtime hardening
- 📦 **Container Runtime** — Podman, Buildah, and Skopeo for containerized workloads
- 🛠️ **Developer-Friendly** — Comprehensive tooling for debugging and development

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

### Default Credentials

| User | Username | Password |
|------|----------|----------|
| Root | `root` | `iotgateway` |
| Developer | `devel` | `devel` |

> ⚠️ **Change default passwords immediately after first boot!**

---

## 🔄 RAUC Over-The-Air Updates

RAUC is **enabled by default** in this distribution.

### Deploy an Update

```bash
# 1. Copy bundle to device
scp build/tmp/deploy/images/raspberrypi5/iot-gw-bundle-full.raucb root@<device-ip>:/tmp/

# 2. Install and reboot
rauc install /tmp/iot-gw-bundle-full.raucb
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

## 💿 Partition Layout

### Default 16GB Layout (RAUC A/B)

| Device | Label | Size | Mount | Purpose |
|--------|-------|------|-------|---------|
| `/dev/mmcblk0p1` | `boot` | 256M | `/boot` | Bootloader & kernel (shared) |
| `/dev/mmcblk0p2` | `rootA` | 3G | `/` | Root filesystem Slot A |
| `/dev/mmcblk0p3` | `rootB` | 3G | - | Root filesystem Slot B |
| `/dev/mmcblk0p4` | `data` | 2G | `/data` | Persistent data |

**Other sizes available:** 32GB, 64GB — see `meta-iot-gateway/wic/` for WKS files.

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

---

## 🎨 Customization

### Layer Management

Two approaches:

| Approach | When to Use | Config File |
|----------|-------------|-------------|
| **Auto-Fetch** (Default) | First-time users, single project | `kas/rpi5-autofetch.yml` |
| **Local Clones** | Multi-project, CI/CD | `kas/rauc.yml` |

Switch by editing the `includes:` section in `kas/local.yml`.

### WiFi Configuration

**Option 1: Build-time injection** (in `kas/local.yml`):
```yaml
local_conf_header:
  wifi: |
    IOTGW_WIFI_SSID = "YourSSID"
    IOTGW_WIFI_PSK = "YourPassword"
```

**Option 2: First-boot provisioning**:
Place `.nmconnection` files in `/boot/iotgw/nm/` before first boot.

### Kernel Features

Enable optional kernel feature sets via `IOTGW_KERNEL_FEATURES`:
- `igw_containers` — Namespaces, cgroups for containers
- `igw_networking_iot` — WireGuard, CAN, VLAN
- `igw_security_prod` — KSPP hardening (recommended for production)
- `igw_observability_dev` — BPF, kprobes, ftrace (development only)

Example (in `kas/local.yml`):
```yaml
local_conf_header:
  kernel_features: |
    IOTGW_KERNEL_FEATURES = "igw_containers igw_networking_iot igw_security_prod"
```

### Optional: OpenThread Border Router (OTBR)

Enable OTBR support at build time:
```bash
IOTGW_ENABLE_OTBR=1 make dev
# or
IOTGW_ENABLE_OTBR=1 kas build kas/local.yml --target iot-gw-image-dev
```

---

## 🛠️ Common Tasks

### Clean Build

```bash
make clean
```

### Enable Desktop/GUI (Wayland/Weston)

```bash
cp kas/desktop.yml.example kas/desktop.yml
kas build kas/local.yml:kas/desktop.yml --target iot-gw-image-dev
```

### Build Performance Tuning

Edit `BB_NUMBER_THREADS` and `PARALLEL_MAKE` in `rpi5.yml` or your local overlay.

---

## 📚 Documentation

- **Detailed OTA Guide**: See `OTA_UPDATE.md`
- **Security Hardening**: See kernel fragments in `meta-iot-gateway/recipes-kernel/linux/files/fragments/`
- **OTBR Setup**: See `meta-iot-gateway/recipes-connectivity/otbr/README.md`

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
