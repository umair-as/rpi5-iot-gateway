# Networking Configuration

This document describes network setup, WiFi configuration, and first-boot provisioning for the IoT Gateway OS.

## Overview

**Network Manager:** NetworkManager (default backend: wpa_supplicant)
**Default Interfaces:**
- `eth0` — Ethernet (DHCP by default)
- `wlan0` — WiFi (configured via build-time or first-boot provisioning)
- `br0` — Bridge interface (192.168.100.1/24, never-default route)

---

## WiFi Configuration

### Method 1: Build-time Injection (Single Network)

Configure WiFi credentials in your KAS overlay (`kas/local.yml`):

```yaml
local_conf_header:
  wifi: |
    IOTGW_WIFI_SSID = "YourSSID"
    IOTGW_WIFI_PSK = "YourPassword"  # Can be plaintext password or WPA-PSK hex (64 chars)
```

**Result:** WiFi credentials baked into the image at build time.

**⚠️ Security Note:**
- PSK can be plaintext password OR 64-character hex WPA-PSK
- Generate WPA-PSK: `wpa_passphrase "YourSSID" "YourPassword"`
- Credentials are embedded in the image. Use first-boot provisioning for better security.

---

### Method 2: Build-time Injection (Multiple Networks)

For multiple WiFi networks with priority, static IPs, and custom DNS:

```yaml
local_conf_header:
  wifi: |
    IOTGW_WIFI_NETWORKS = "HomeWiFi|Secret123|wlan0|manual|100|192.168.0.222/24|192.168.0.1|1.1.1.1;8.8.8.8\nOfficeWiFi|AnotherPass|wlan0|auto|90|||"
```

**Format:** `ssid|psk|iface|method|priority|ipv4addr/prefix|gateway|dns1;dns2`

**Fields:**
- `ssid` — Network name
- `psk` — Pre-shared key (plaintext password or 64-char hex WPA-PSK)
- `iface` — Interface name (usually `wlan0`)
- `method` — `manual` (static IP) or `auto` (DHCP)
- `priority` — Connection priority (higher = preferred)
- `ipv4addr/prefix` — Static IP and subnet (e.g., `192.168.1.100/24`)
- `gateway` — Default gateway
- `dns1;dns2` — DNS servers (semicolon-separated)

**Generate WPA-PSK:** `wpa_passphrase "YourSSID" "YourPassword"` (use the hex output)

**Empty fields:** Leave blank for DHCP (e.g., `||||`)

---

### Method 3: First-boot Provisioning (Recommended)

Place NetworkManager connection files on the boot partition before first boot:

**Location:** `/boot/iotgw/nm/*.nmconnection`

**Example WiFi Connection:**

```bash
# On your workstation, create connection file
cat > HomeWiFi.nmconnection <<'EOF'
[connection]
id=HomeWiFi
uuid=12345678-1234-1234-1234-123456789abc
type=wifi
interface-name=wlan0
autoconnect=true
autoconnect-priority=100

[wifi]
ssid=YourSSID
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=YourPassword

[ipv4]
method=auto

[ipv6]
method=auto
EOF

# Mount boot partition of SD card
sudo mount /dev/sdX1 /mnt

# Copy to provisioning location
sudo mkdir -p /mnt/iotgw/nm
sudo cp HomeWiFi.nmconnection /mnt/iotgw/nm/
sudo chmod 600 /mnt/iotgw/nm/HomeWiFi.nmconnection

# Unmount
sudo umount /mnt
```

**On first boot**, the `iotgw-provision` service:
1. Copies `.nmconnection` files from `/boot/iotgw/nm/` to `/etc/NetworkManager/system-connections/`
2. Sets correct permissions (600, root:root)
3. Reloads NetworkManager
4. Removes files from `/boot/iotgw/nm/` (for security)

---

### Method 4: Runtime Configuration (On Device)

**Using nmcli:**

```bash
# Add WiFi connection
nmcli device wifi connect "YourSSID" password "YourPassword"

# Add with static IP
nmcli connection add type wifi ifname wlan0 con-name MyWiFi ssid YourSSID \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "YourPassword" \
  ipv4.method manual ipv4.addresses 192.168.1.100/24 ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1 8.8.8.8"

# List connections
nmcli connection show

# Activate connection
nmcli connection up MyWiFi

# Delete connection
nmcli connection delete MyWiFi
```

**Using nmtui (text UI):**

```bash
nmtui
```

---

## Ethernet Configuration

### Default (DHCP)

Ethernet (`eth0`) is configured for DHCP by default.

### Static IP

**Via nmcli:**

```bash
nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.50/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1 8.8.8.8"

nmcli connection up "Wired connection 1"
```

**Via provisioning:** Place ethernet connection file in `/boot/iotgw/nm/`

---

## Bridge Interface (br0)

A bridge interface is pre-configured for container/VM networking:

**Configuration:**
- IP: `192.168.100.1/24`
- DHCP: Not enabled (static only)
- Route: `ipv4.never-default=true` (doesn't override default gateway)

**Use Cases:**
- Podman/Docker bridge networking
- VM networking
- Isolated network for testing

**Attach Interface to Bridge:**

```bash
# Add eth1 to br0
nmcli connection add type bridge-slave ifname eth1 master br0
```

---

## MAC Address Randomization

**Default Settings:**
- **Scan-time randomization:** `yes` (randomize MAC during WiFi scanning)
- **Connection MAC policy:** `stable` (preserve per-connection, not fully random)

**Configured via:**
- `IOTGW_NM_SCAN_RAND` — Scan-time randomization
- `IOTGW_NM_WIFI_CLONED_MAC` — Connection-level policy

**Options for `IOTGW_NM_WIFI_CLONED_MAC`:**
- `preserve` — Use hardware MAC
- `random` — Fully random on each connection
- `stable` — Deterministic hash (same network = same MAC)

**Change in KAS overlay:**

```yaml
local_conf_header:
  wifi_mac: |
    IOTGW_NM_WIFI_CLONED_MAC = "random"
```

**Change at runtime:**

```bash
nmcli connection modify MyWiFi wifi.cloned-mac-address random
nmcli connection up MyWiFi
```

---

## NetworkManager Backend

**Default:** `wpa_supplicant`

**Alternative:** `iwd` (Intel Wireless Daemon)

**Change backend at build time:**

Place custom config in `/boot/iotgw/nm-conf/`:

```bash
cat > /boot/iotgw/nm-conf/wifi-backend.conf <<'EOF'
[device]
wifi.backend=iwd
EOF
```

Or in KAS overlay, add a recipe to install `/etc/NetworkManager/conf.d/wifi-backend.conf`.

---

## First-boot Provisioning

The `iotgw-provision` service runs NetworkManager provisioning once on first boot.

### Provisioning Locations

SSH keys are not handled by the provisioning service. See "Developer SSH Keys" for dev-only key installation.

**NetworkManager Connections:**
```
/boot/iotgw/nm/*.nmconnection  →  /etc/NetworkManager/system-connections/
```

**NetworkManager Configuration:**
```
/boot/iotgw/nm-conf/*.conf  →  /etc/NetworkManager/conf.d/
```

### Provisioning Workflow

1. Flash image to SD card
2. Mount boot partition (`/dev/sdX1`)
3. Create `/boot/iotgw/` directory structure
4. Add provisioning files
5. Unmount and boot
6. Provisioning service copies files and removes originals
7. NetworkManager reloads, SSH keys applied

**Example:**

```bash
# Mount boot partition
sudo mount /dev/sdX1 /mnt

# Create directories
sudo mkdir -p /mnt/iotgw/{nm,nm-conf}

# Add SSH key
sudo cp ~/.ssh/id_rsa.pub /mnt/iotgw/authorized_keys

# Add WiFi connection
sudo cp HomeWiFi.nmconnection /mnt/iotgw/nm/
sudo chmod 600 /mnt/iotgw/nm/HomeWiFi.nmconnection

# Unmount
sudo umount /mnt
```

### Provisioning Service

**Systemd Unit:** `iotgw-provision.service`

**Script:** `/usr/bin/iotgw-provision.sh`

**Logs:**
```bash
journalctl -u iotgw-provision
```

**Disable after first boot:** Network provisioning is stamped and skipped on subsequent boots.

---

## Firewall (nftables)

The distribution uses nftables for firewall configuration.

**Default Policy:**
- INPUT: Accept (adjust for production)
- FORWARD: Accept (for container/bridge networking)
- OUTPUT: Accept

**Configuration:** `/etc/nftables.conf`

**Basic Rules Example:**

```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        # Allow established/related
        ct state established,related accept

        # Allow loopback
        iif lo accept

        # Allow SSH
        tcp dport 22 accept

        # Allow ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

**Reload:**
```bash
nft -f /etc/nftables.conf
# or
systemctl reload nftables
```

---

## Additional Resources

- [NetworkManager Documentation](https://networkmanager.dev/)
- [nmcli Examples](https://www.networkmanager.dev/docs/api/latest/nmcli-examples.html)
