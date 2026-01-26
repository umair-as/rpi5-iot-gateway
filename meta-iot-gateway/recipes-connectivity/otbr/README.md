# OpenThread Border Router (OTBR) for Raspberry Pi 5

This layer provides **OpenThread Border Router** support for Raspberry Pi 5 as a **Podman/Docker container**.

## Overview

- 🌐 **Border Router** — Connects Thread mesh networks to IP networks
- 📦 **Containerized** — Runs in Podman/Docker for isolation and portability
- 🔧 **Full-featured** — Web UI, mDNS, NAT64, SRP, Commissioner
- 🎯 **RPi5 optimized** — Configured for Raspberry Pi 5 hardware

## What's Included

| Component | Description |
|-----------|-------------|
| `otbr-rpi5.bb` | Base OTBR recipe (upstream ot-br-posix) |
| `otbr-rpi5-container.bb` | OCI container image recipe |
| `entrypoint.sh` | Container startup script |
| `kas/otbr.yml` | KAS overlay for building with OTBR |

## Hardware Requirements

- **Raspberry Pi 5**
- **Thread RCP (Radio Co-Processor)**:
  - nRF52840 USB Dongle (recommended)
  - nRF52840 DK
  - Any OpenThread RCP over UART/USB

## Building

### Build OTBR Container Image

```bash
# Using KAS overlay
kas build kas/otbr.yml --target otbr-rpi5-container

# Or add to your custom overlay
IMAGE_INSTALL:append = " otbr-rpi5-container"
IMAGE_FSTYPES:append = " oci"
```

The build produces:
- `otbr-rpi5-container-<machine>-<timestamp>.rootfs-oci.tar` — OCI image tarball
- Container ready to load into Podman/Skopeo

## Deployment

### 1. Copy OCI Image to Device

```bash
# Copy the OCI tarball to your RPi5
scp build/tmp/deploy/images/raspberrypi5/otbr-rpi5-container-*.rootfs-oci.tar \
    root@rpi5:/tmp/
```

### 2. Load into Podman

```bash
# On the RPi5
cd /tmp
tar xf otbr-rpi5-container-*.rootfs-oci.tar

# Load the OCI image
skopeo copy oci:otbr-rpi5-container-*:latest \
    containers-storage:localhost/otbr-rpi5:latest
```

### 3. Run the Container

```bash
# Run with RCP on /dev/ttyACM0 (nRF52840 USB dongle)
podman run -d \
    --name otbr \
    --network host \
    --privileged \
    --device=/dev/ttyACM0 \
    -e OTBR_RCP_BUS=ttyACM0 \
    -e OTBR_INFRA_IF=eth0 \
    -e OTBR_LOG_LEVEL=info \
    localhost/otbr-rpi5:latest
```

### 4. Access OTBR Web Interface

Open browser to: `http://<rpi5-ip>:80`

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OTBR_INFRA_IF` | `eth0` | Infrastructure network interface |
| `OTBR_RCP_BUS` | `ttyACM0` | RCP serial device name |
| `OTBR_LOG_LEVEL` | `info` | Log level (debug, info, warn, error) |

### Example: Custom Configuration

```bash
podman run -d \
    --name otbr \
    --network host \
    --privileged \
    --device=/dev/ttyUSB0 \
    -e OTBR_RCP_BUS=ttyUSB0 \
    -e OTBR_INFRA_IF=wlan0 \
    -e OTBR_LOG_LEVEL=debug \
    localhost/otbr-rpi5:latest
```

## Container Management

```bash
# View logs
podman logs -f otbr

# Stop container
podman stop otbr

# Start container
podman start otbr

# Remove container
podman rm otbr

# Inspect container
podman inspect otbr
```

## Systemd Service (Optional)

Create `/etc/systemd/system/otbr-container.service`:

```ini
[Unit]
Description=OpenThread Border Router Container
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman stop otbr
ExecStartPre=-/usr/bin/podman rm otbr
ExecStart=/usr/bin/podman run \
    --name otbr \
    --network host \
    --privileged \
    --device=/dev/ttyACM0 \
    -e OTBR_RCP_BUS=ttyACM0 \
    -e OTBR_INFRA_IF=eth0 \
    localhost/otbr-rpi5:latest
ExecStop=/usr/bin/podman stop otbr
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
systemctl daemon-reload
systemctl enable --now otbr-container
```

## Troubleshooting

### Container won't start

```bash
# Check if RCP device exists
ls -la /dev/ttyACM*

# Check podman logs
podman logs otbr

# Run interactively for debugging
podman run -it --rm \
    --network host \
    --privileged \
    --device=/dev/ttyACM0 \
    localhost/otbr-rpi5:latest \
    /bin/bash
```

### RCP not detected

```bash
# Check USB devices
lsusb

# Check kernel logs
dmesg | grep -i usb

# For nRF52840, should see: SEGGER J-Link or Nordic Semiconductor
```

### Web interface not accessible

```bash
# Check if port 80 is listening
netstat -tulpn | grep :80

# Check firewall
nft list ruleset | grep 80
```

## Features Enabled

- ✅ Border Routing
- ✅ Web Interface (port 80)
- ✅ DBus API
- ✅ SRP Advertising Proxy
- ✅ mDNS (Avahi)
- ✅ NAT64
- ✅ Commissioner
- ✅ TREL (Thread over IP)
- ✅ Backbone Router
- ✅ DNS-SD Discovery Proxy

## Architecture

```
┌─────────────────────────────────────────┐
│  Raspberry Pi 5 Host                    │
│                                         │
│  ┌────────────────────────────────┐    │
│  │  OTBR Container (Podman)       │    │
│  │                                │    │
│  │  ┌──────────┐  ┌───────────┐  │    │
│  │  │ otbr-    │  │ otbr-web  │  │    │
│  │  │ agent    │  │ (port 80) │  │    │
│  │  └────┬─────┘  └───────────┘  │    │
│  │       │                        │    │
│  │       │ spinel+hdlc+uart       │    │
│  │       │                        │    │
│  └───────┼────────────────────────┘    │
│          │                             │
│     /dev/ttyACM0 (--device)            │
│          │                             │
│  ┌───────▼────────┐                    │
│  │  nRF52840 RCP  │ (Thread Radio)     │
│  └────────────────┘                    │
└─────────────────────────────────────────┘
```

## References

- [OpenThread](https://openthread.io/)
- [OTBR Guide](https://openthread.io/guides/border-router)
- [Thread Specification](https://www.threadgroup.org/)
