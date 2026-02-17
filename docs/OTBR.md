# OpenThread Border Router (OTBR)

This document describes how to enable and use OpenThread Border Router on the IoT Gateway OS.

## Overview

**OpenThread Border Router (OTBR)** connects Thread mesh networks to IP networks, enabling:
- Thread device commissioning
- Border routing between Thread and IP networks
- Web-based management interface
- mDNS service discovery
- NAT64 for IPv4 connectivity

**Deployment Mode:** Host-based (systemd services)
**Hardware:** Raspberry Pi 5 + Thread RCP

---

## Hardware Requirements

### Required

- **Raspberry Pi 5**
- **Thread RCP (Radio Co-Processor)**:
  - ESP32-H2 (recommended, tested with esp-idf)
  - nRF52840 USB Dongle
  - nRF52840 DK
  - Any OpenThread-compatible RCP over UART/USB

### RCP Firmware

The RCP must be flashed with OpenThread RCP firmware.

**ESP32-H2 (esp-idf):**

```bash
# Clone ESP-IDF
git clone --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32h2

cd esp-idf/examples/openthread/ot_rcp

# Build and flash RCP firmware
idf.py set-target esp32h2
idf.py build
idf.py flash
```

---

## Building with OTBR

### Enable OTBR at Build Time

**Option 1: Environment Variable**

```bash
IOTGW_ENABLE_OTBR=1 make dev
# or
IOTGW_ENABLE_OTBR=1 kas build kas/local.yml --target iot-gw-image-dev
```

**Option 2: KAS Overlay**

In `kas/local.yml`:

```yaml
local_conf_header:
  otbr: |
    IOTGW_ENABLE_OTBR = "1"
```

Then build normally:
```bash
kas build kas/local.yml --target iot-gw-image-dev
```

### What Gets Installed

When enabled, the following are included:
- `otbr-rpi5` package (otbr-agent, otbr-web)
- systemd services (otbr-agent, otbr-web)
- Dependencies (Avahi, radvd)
- Firewall rules for OTBR web UI (only when `IOTGW_ENABLE_OTBR=1`)
- Kernel features (netfilter, NAT support)

**Note:** Ensure `igw_networking_iot` kernel features are enabled for nftables/NAT support.

### Thread Version

Default Thread version is **1.4**. Override in `kas/local.yml` if needed:

```yaml
local_conf_header:
  otbr: |
    IOTGW_OT_THREAD_VERSION = "1.4"
```

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  Raspberry Pi 5 Host                        │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  otbr-agent (systemd service)        │  │
│  │  - Thread network management         │  │
│  │  - Border routing                    │  │
│  │  - Commissioner                      │  │
│  └────────┬─────────────────────────────┘  │
│           │                                 │
│           │ spinel+hdlc+uart                │
│           │ (/dev/ttyUSB0, 115200)          │
│           │                                 │
│  ┌────────▼─────────┐                       │
│  │  ESP32-H2 RCP    │ Thread Radio          │
│  └──────────────────┘                       │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  otbr-web (systemd service)          │  │
│  │  - Web UI (port 80)                  │  │
│  │  - Network management                │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  nftables (firewall/NAT)             │  │
│  │  - Thread ↔ IP routing               │  │
│  │  - Masquerade Thread traffic         │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  Interfaces:                                │
│  - wpan0: Thread network interface          │
│  - eth0: Infrastructure network (default)   │
└─────────────────────────────────────────────┘
```

---

## Performance Considerations

### Resource Usage

**CPU:** Low (~5% idle, ~10% active)
**Memory:** ~50MB (otbr-agent + otbr-web)
**Network:** Minimal (<1Mbps typical)

### Optimization

**Disable web UI if not needed:**
```bash
systemctl stop otbr-web
systemctl disable otbr-web
```

**Reduce logging:**
```bash
# Edit /etc/default/otbr-agent and add a debug flag
OTBR_AGENT_OPTS="... -d 3"
```

---

## OTBR D-Bus CLI (Testing)

The image includes a lightweight D-Bus client for OTBR testing and debugging.

**Binary:** `iotgw-otbrctl`

**Examples:**
```bash
# Basic status
iotgw-otbrctl get DeviceRole
iotgw-otbrctl get NetworkName

# Scans
iotgw-otbrctl scan
iotgw-otbrctl --output json energy-scan 1000

# Network operations
iotgw-otbrctl attach --network-name Demo --panid 4660 --channel-mask 0x07fff800
iotgw-otbrctl detach
iotgw-otbrctl permit-join 0 60
iotgw-otbrctl factory-reset --yes

# Prefix and routes
iotgw-otbrctl add-on-mesh-prefix fd00:1234::/64 --preferred true --slaac true
iotgw-otbrctl remove-on-mesh-prefix fd00:1234::/64
iotgw-otbrctl add-external-route 2001:db8::/64 --stable true
iotgw-otbrctl remove-external-route 2001:db8::/64

# NAT64
iotgw-otbrctl nat64 enable
iotgw-otbrctl nat64 disable

# Border Agent + MeshCoP TXT
iotgw-otbrctl border-agent disable
iotgw-otbrctl border-agent enable
iotgw-otbrctl meshcop-txt vendor=0x69746777 model=0x6f746272

# Ephemeral key (ePSKc)
iotgw-otbrctl epskc-activate 0
iotgw-otbrctl epskc-deactivate false
```

**Notes:**
- Some properties are build-dependent; `Not implemented in this build` is expected if the feature is disabled.
- JSON output is JSON Lines for dashboard ingestion (`--output json`).

---

## Security Considerations

### Network Isolation

**Firewall OTBR web interface:**
```bash
# Allow only local access
nft add rule inet filter input tcp dport 80 ip saddr != 192.168.0.0/16 drop
```

### Commissioner Security

- Use strong PSKd credentials (8+ characters)
- Disable commissioner when not actively commissioning
- Monitor commissioner activity in logs

### Thread Network Security

- Use unique network keys (automatically generated)
- Rotate network credentials periodically
- Monitor for unauthorized devices

---

## Additional Resources

- [OpenThread Documentation](https://openthread.io/)
- [OTBR Guide](https://openthread.io/guides/border-router)
- [Thread Specification](https://www.threadgroup.org/)
