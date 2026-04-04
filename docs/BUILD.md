# Build Guide

This document describes how to build the IoT Gateway OS images.

## Overview

The IoT Gateway OS uses **KAS** (setup tool for BitBake) wrapped by a Makefile for convenience.

**Build Tool:** KAS + BitBake (Yocto Project)
**Distribution:** iotgw
**Machine:** raspberrypi5

---

## Quick Start

```bash
# Copy example config
cp kas/local.yml.example kas/local.yml
# Edit kas/local.yml with your keys/WiFi

# Build images
make dev         # Development image
make prod        # Production image
make base        # Base image
make desktop     # Desktop image (Wayland/Weston)

# Build OTA bundles
make bundle-dev-full      # Dev image + kernel bundle
make bundle-prod-full     # Prod image + kernel bundle
make bundle-desktop-full  # Desktop image + kernel bundle
```

---

## Makefile Targets

```bash
# Show all available targets
make help
```

### Image Targets

```bash
make dev         # iot-gw-image-dev
make prod        # iot-gw-image-prod
make base        # iot-gw-image-base
make desktop     # iot-gw-image-desktop
```

### Bundle Targets

```bash
make bundle-dev-full      # Full bundle (rootfs + kernel) for dev image
make bundle-prod-full     # Full bundle (rootfs + kernel) for prod image
make bundle-desktop-full  # Full bundle (rootfs + kernel) for desktop image
make bundle-desktop       # Rootfs-only bundle for desktop image
```

### Utility Targets

```bash
make clean       # Clean build artifacts
make help        # Show all targets
```

---

## Environment Variables

Pass variables to builds via environment:

```bash
# Enable OTBR
IOTGW_ENABLE_OTBR=1 make dev

# Custom kernel features
IOTGW_KERNEL_FEATURES="igw_containers igw_security_prod" make prod

# Enable native observability stack (InfluxDB + Telegraf)
IOTGW_ENABLE_OBSERVABILITY=1 make dev
```

### Versioning Overrides

The distro and RAUC bundle versioning policy is defined in
`meta-iot-gateway/conf/distro/include/iotgw-common.inc`.

Defaults:
- `DISTRO_VERSION = igw.<major>.<minor>.<patch>`
- `RAUC_BUNDLE_VERSION = <DISTRO_VERSION>-<MACHINE>-<image-track>-b<IOTGW_BUILD_ID>`

Example release override:
```bash
IOTGW_VERSION_MAJOR=0 \
IOTGW_VERSION_MINOR=2 \
IOTGW_VERSION_PATCH=0 \
IOTGW_BUILD_ID=20260401 \
make bundle-prod-full
```

---

## Layer Management

The Makefile uses `kas/local.yml` as the entry point. By default, it includes `kas/rpi5-autofetch.yml` (auto-fetch mode).

### Auto-fetch Mode (Default)

KAS automatically downloads all required layers.

**No setup required** — just run `make dev`

### Local Clones Mode

Switch to local clones by editing `kas/local.yml`:

```yaml
header:
  version: 18
  includes:
    - "kas/rauc.yml"  # Switch from rpi5-autofetch.yml to rauc.yml
```

**Setup local layers:**

```bash
mkdir -p ~/yocto_resource/layers
cd ~/yocto_resource/layers

git clone -b scarthgap https://github.com/openembedded/openembedded-core.git
git clone -b scarthgap https://github.com/openembedded/bitbake.git
git clone -b scarthgap https://github.com/agherzan/meta-raspberrypi.git
git clone -b scarthgap https://github.com/openembedded/meta-openembedded.git
git clone -b scarthgap https://github.com/meta-qt5/meta-qt5.git
git clone -b scarthgap https://github.com/rauc/meta-rauc.git
git clone -b scarthgap https://github.com/rauc/meta-rauc-community.git
git clone -b scarthgap https://github.com/meta-python/meta-python.git
git clone -b scarthgap https://github.com/kraj/meta-clang.git
```

---

## Build Configuration

### Parallel Builds

Edit `rpi5.yml` or `kas/local.yml`:

```yaml
local_conf_header:
  parallel: |
    BB_NUMBER_THREADS = "8"
    PARALLEL_MAKE = "-j10"
```

### Shared Cache Directories

```yaml
local_conf_header:
  sstate: |
    SSTATE_DIR = "${HOME}/yocto_resource/SSTATE"
  downloads: |
    DL_DIR = "${HOME}/yocto_resource/DL_SHARED"
  hashserve: |
    BB_HASHSERVE = "auto"
```

---

## Direct KAS Usage

You can also use KAS directly without the Makefile:

```bash
# Build image
kas build kas/local.yml --target iot-gw-image-dev

# Build bundle
kas build kas/local.yml --target iot-gw-bundle-full

# Interactive shell
kas shell kas/local.yml
```

## OTA Reference

- RAUC install/update runbook: `docs/RAUC_UPDATE.md`

---

## BitBake Shell

Access BitBake environment:

```bash
kas shell kas/local.yml
```

Inside shell:
```bash
bitbake iot-gw-image-dev
bitbake -c cleansstate virtual/kernel
bitbake-layers show-layers
```

---

## CI/CD Integration

### GitLab CI

```yaml
build:
  image: ghcr.io/siemens/kas/kas:latest
  script:
    - kas build kas/rpi5-autofetch.yml --target iot-gw-image-prod
  artifacts:
    paths:
      - build/tmp/deploy/images/
```

### GitHub Actions

```yaml
name: Build

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/siemens/kas/kas:latest
    steps:
      - uses: actions/checkout@v3
      - name: Build image
        run: kas build kas/rpi5-autofetch.yml --target iot-gw-image-prod
      - uses: actions/upload-artifact@v3
        with:
          name: images
          path: build/tmp/deploy/images/
```

---

## Additional Resources

- [KAS Documentation](https://kas.readthedocs.io/)
- [Yocto Project Documentation](https://docs.yoctoproject.org/)
- [BitBake User Manual](https://docs.yoctoproject.org/bitbake/)
- [FIT Setup and Signing Guide](FIT_SIGNING.md)
