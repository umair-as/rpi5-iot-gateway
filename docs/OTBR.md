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

### Web UI

The web management interface is provided by **otbr-webui** — a standalone
React + Fastify application that replaces the legacy C++ `otbr-web` binary
shipped upstream by ot-br-posix.

Key differences from the legacy web UI:

| | Legacy `otbr-web` | New `otbr-webui` |
|---|---|---|
| **Runtime** | C++ binary | Node.js + Fastify |
| **Frontend** | Alpine.js (single HTML) | React 19 + Vite (bundled) |
| **Real-time** | Polling only | WebSocket push + REST |
| **Topology** | D3.js (basic) | D3.js force-directed graph |
| **Features** | Dashboard, network, commissioner | Dashboard, topology, network, commissioner, dataset, diagnostics, energy scan |
| **Air-gapped** | Vendored JS/fonts | Vendored (Roboto, Material Icons, all npm deps) |
| **Security** | systemd hardening | Same hardening + CSP headers, input validation, strict ot-ctl whitelist |

The `otbr-rpi5` recipe builds the OTBR agent with `-DOTBR_WEB=OFF` and
depends on `otbr-webui` for the web interface. Source:
[github.com/umair-as/otbr-webui](https://github.com/umair-as/otbr-webui)

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
- `otbr-rpi5` package (otbr-agent + dependencies)
- `otbr-webui` package (React/Fastify web UI + Node.js runtime)
- systemd services: `otbr-agent.service`, `otbr-webui.service`
- Dependencies (Avahi, radvd, Node.js 22 LTS)
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
┌──────────────────────────────────────────────────┐
│  Raspberry Pi 5 Host                             │
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │  otbr-agent (systemd service)             │  │
│  │  - Thread network management              │  │
│  │  - Border routing                         │  │
│  │  - Commissioner                           │  │
│  │  - REST API on :8081                      │  │
│  └────────┬──────────────────────────────────┘  │
│           │                                      │
│           │ spinel+hdlc+uart                     │
│           │ (/dev/ttyUSB0, 460800)               │
│           │                                      │
│  ┌────────▼──────────┐                           │
│  │  ESP32-H2 RCP     │ Thread Radio              │
│  └───────────────────┘                           │
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │  otbr-webui (systemd service, port 80)    │  │
│  │  Node.js + Fastify                        │  │
│  │  ├── Static files (React SPA)             │  │
│  │  ├── /api/* proxy → otbr-agent :8081      │  │
│  │  ├── /api/ot/* → ot-ctl subprocess        │  │
│  │  └── /ws WebSocket (real-time push)       │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │  nftables (firewall/NAT)                  │  │
│  │  - Thread ↔ IP routing                    │  │
│  │  - Masquerade Thread traffic              │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  Interfaces:                                     │
│  - wpan0: Thread network interface               │
│  - eth0/wlan0: Infrastructure network            │
└──────────────────────────────────────────────────┘
```

---

## Web UI Configuration

The web UI is configured via `/etc/default/otbr-webui`:

```bash
PORT=80                                        # Listen port
HOST=0.0.0.0                                   # Bind address
OTBR_AGENT_URL=http://localhost:8081           # otbr-agent REST API
STATIC_DIR=/usr/share/otbr-webui/dist/client   # React SPA assets
OT_CTL_PATH=/usr/sbin/ot-ctl                   # ot-ctl binary path
```

The service runs as the `otbr` user with systemd hardening (same
`CAP_NET_BIND_SERVICE` capability as the old otbr-web, plus CSP headers
and strict input validation on all ot-ctl operations).

## Performance Considerations

### Resource Usage

**CPU:** Low (~5% idle, ~10% active)
**Memory:** ~60MB (otbr-agent + otbr-webui + Node.js)
**Network:** Minimal (<1Mbps typical)

### Optimization

**Disable web UI if not needed:**
```bash
systemctl stop otbr-webui
systemctl disable otbr-webui
```

**Reduce logging:**
```bash
# Edit /etc/default/otbr-agent and add a debug flag
OTBR_AGENT_OPTS="... -d 3"
```

## Troubleshooting

### `otbr-agent` restarts with `InitMulticastRouterSock() ... Protocol not available`

If `journalctl -u otbr-agent` shows:

```text
InitMulticastRouterSock() ... Protocol not available
otbr-agent.service: Main process exited, status=5/NOTINSTALLED
```

the kernel is missing multicast-routing support required by OTBR backbone
router mode (`-B <infra-if>`).

This layer enables the required options in
`networking-iot.cfg`:

- `CONFIG_IPV6_MROUTE=y`
- `CONFIG_IP_MROUTE=y`

If you hit this on an older image, either:

1. Boot an image with these kernel options enabled (recommended), or
2. As a temporary workaround, remove backbone mode from
   `/etc/default/otbr-agent` by removing `-B wlan0` from `OTBR_AGENT_OPTS`
   and restarting `otbr-agent`.

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

## OTBR REST CLI Wrappers (curl + jq)

For quick API diagnostics against the local OTBR REST server (`127.0.0.1:8081`):

```bash
# Node snapshot
scripts/ot-demo/otbr-api-node.sh

# Device discovery action + polling + device summary
scripts/ot-demo/otbr-api-discover.sh --device-count 10 --timeout 30

# Energy scan action + polling + report
scripts/ot-demo/otbr-api-energy-scan.sh --channels 11,12,13,14 --count 1 --period 32
```

You can target a remote endpoint via `BASE_URL`:

```bash
BASE_URL=http://192.168.0.82:8081 scripts/ot-demo/otbr-api-node.sh
```
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

**Firewall OTBR web interface (otbr-webui on port 80):**
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
