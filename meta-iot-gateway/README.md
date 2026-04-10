<div align="center">

# 🌐 meta-iot-gateway

**Custom Yocto meta-layer for IoT Gateway functionality on Raspberry Pi 5**

[![Layer](https://img.shields.io/badge/Layer-meta--iot--gateway-blue.svg)](.)
[![Compatible](https://img.shields.io/badge/Compatible-Yocto%20Scarthgap-orange.svg)](https://docs.yoctoproject.org)
[![BSP](https://img.shields.io/badge/BSP-Raspberry%20Pi%205-c51a4a.svg)](https://www.raspberrypi.com/products/raspberry-pi-5/)

</div>

---

## 📖 Description

This layer provides IoT gateway packages and configurations used by this project:

- 📡 **MQTT** — Mosquitto broker and clients for messaging
- 📊 **Time-Series Databases** — Optimized for sensor data
- 🐳 **Container Runtime** — Podman, Buildah, Skopeo support
- 🔌 **IoT Protocols** — MQTT and Thread/OTBR support

---

## 🔗 Layer Dependencies

This layer depends on the following OpenEmbedded layers:

| Layer | Repository | Purpose |
|-------|------------|---------|
| **meta** | [openembedded-core](https://git.openembedded.org/openembedded-core) | Core OE functionality |
| **meta-oe** | [meta-openembedded](https://github.com/openembedded/meta-openembedded) | Extended packages |
| **meta-python** | [meta-openembedded](https://github.com/openembedded/meta-openembedded) | Python ecosystem |
| **meta-networking** | [meta-openembedded](https://github.com/openembedded/meta-openembedded) | Networking tools |
| **meta-raspberrypi** | [meta-raspberrypi](https://github.com/agherzan/meta-raspberrypi) | Raspberry Pi BSP |

---

## 🛠️ Key Features

### Image Recipes

- **`iot-gw-image-base`** — Standard gateway with package management
- **`iot-gw-image-dev`** — Development variant with debug tools
- **`iot-gw-image-prod`** — Production-hardened variant

### Package Groups

- **`packagegroup-iot-gw-base`** — Essential system packages
- **`packagegroup-iot-gw-apps`** — IoT applications and services
- **`packagegroup-iot-gw-devtools`** — Development and debugging tools

### System Enhancements

- 🔐 **Security**: nftables firewall, AppArmor profiles
- 📋 **Logging**: Configured journald with persistence
- 🌐 **Networking**: NetworkManager with Wi-Fi/Ethernet profiles
- 🔄 **OTA Updates**: RAUC A/B update framework
- 🐳 **Containers**: Podman/Buildah for containerized workloads

---

## 📝 Usage

Add this layer to your `bblayers.conf`:

```bitbake
BBLAYERS += "${TOPDIR}/../meta-iot-gateway"
```

Or use KAS configuration (recommended):

```yaml
repos:
  meta-iot-gateway:
    path: meta-iot-gateway
```

Build an image:

```bash
bitbake iot-gw-image-dev
```

---

## 👤 Maintainer

**Umair A.S** • [@umair-as](https://github.com/umair-as)

---

## 📄 License

This layer is MIT licensed. Individual recipes may have different licenses — check recipe headers.
