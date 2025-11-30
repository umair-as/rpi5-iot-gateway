# Kernel Configuration

This document describes the kernel configuration system and available feature sets.

## Overview

The distribution uses **modular kernel configuration** based on feature fragments.

**Base Kernel:** Linux 6.6 (Raspberry Pi kernel)

**Always Enabled:**
- `branding.cfg` — Kernel version suffix (`-v8-16k-igw`)
- `storage-filesystems.cfg` — OverlayFS, dm-verity, SquashFS (required for RAUC)

**Optional Feature Sets:** Controlled via `IOTGW_KERNEL_FEATURES` variable

**Fragment Location:** `meta-iot-gateway/recipes-kernel/linux/files/fragments/`

---

## Available Feature Sets

### `igw_compute_media`

Graphics, video, and media processing support.

**Features:** DRM/KMS, V4L2, camera support, huge pages

**Use for:** GPU acceleration, camera/video processing, display output

**CMA Configuration:**
```bash
# Increase CMA for camera/video if needed
fw_setenv EXTRA_KERNEL_ARGS "cma=256M"
reboot
```

---

### `igw_containers`

Container runtime support (Podman, Docker).

**Features:** Namespaces, cgroups, overlay filesystem, seccomp

**Required for:** Podman, Docker, LXC

---

### `igw_networking_iot`

IoT networking protocols and features.

**Features:** WireGuard VPN, SocketCAN, VLANs, netfilter/nftables

**Includes:**
- WireGuard VPN
- CAN bus (MCP2515 SPI controller)
- VLAN 802.1Q
- nftables for firewall/NAT (required for OTBR)

**CAN Bus Setup:**
```bash
modprobe can_mcp251x
ip link set can0 type can bitrate 500000
ip link set can0 up
```

---

### `igw_observability_dev`

Kernel debugging and tracing (development only).

**Features:** BPF/eBPF, ftrace, kprobes, perf events, debug symbols

**⚠️ WARNING:** Development only! Do not use in production.

**Usage:**
```bash
# Trace system calls
bpftrace -e 'tracepoint:syscalls:sys_enter_* { @[probe] = count(); }'

# Function tracing
echo function > /sys/kernel/debug/tracing/current_tracer
cat /sys/kernel/debug/tracing/trace
```

---

### `igw_security_prod`

Comprehensive kernel hardening for production.

**Features:** KSPP-aligned security configuration

**Categories:**
- Memory protection (FORTIFY, INIT_ON_ALLOC, SLAB hardening)
- Stack protection (canaries, VMAP_STACK, randomization)
- GCC plugins (STACKLEAK, STRUCTLEAK, LATENT_ENTROPY)
- Access restrictions (dmesg, devmem, kcore disabled)
- ASLR (increased entropy)
- Module signing (SHA256, enforced)
- AppArmor LSM
- Audit framework

**See:** `docs/SECURITY.md` for full details

---

## Enabling Feature Sets

### Via KAS Overlay

In `kas/local.yml`:

```yaml
local_conf_header:
  kernel_features: |
    IOTGW_KERNEL_FEATURES = "igw_containers igw_networking_iot igw_security_prod"
```

### Via Environment Variable

```bash
IOTGW_KERNEL_FEATURES="igw_containers igw_networking_iot" make dev
```

---

## Recommended Configurations

### Development Image

```yaml
IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_observability_dev"
```

### Production Image (Minimal)

```yaml
IOTGW_KERNEL_FEATURES = "igw_containers igw_networking_iot igw_security_prod"
```

### Production Image (Full-featured)

```yaml
IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_security_prod"
```

---

## Runtime Kernel Parameters

### U-Boot Environment

```bash
# View current args
fw_printenv bootargs

# Add custom args
fw_setenv EXTRA_KERNEL_ARGS "cma=256M quiet loglevel=3"

# Clear custom args
fw_setenv EXTRA_KERNEL_ARGS ""

# Reboot to apply
reboot
```

### Common Parameters

```
cma=256M              # For camera/video applications
quiet                 # Suppress kernel messages
loglevel=3            # Errors only (3), Info (6), Debug (7)
console=tty1          # Enable console on HDMI
console=serial0,115200  # Enable serial console
```

---

## Kernel Branding

Custom version suffix for identification:

```
CONFIG_LOCALVERSION="-v8-16k-igw"
```

Verify:
```bash
uname -r
# Output: 6.6.x-v8-16k-igw
```

---

## Verifying Configuration

### On Running System

```bash
# Check if feature is enabled
zcat /proc/config.gz | grep CONFIG_WIREGUARD

# Check loaded modules
lsmod | grep wireguard

# Kernel version
uname -a
```

### During Build

```bash
# Interactive kernel config
bitbake -c menuconfig virtual/kernel

# Check config in shell
bitbake -c devshell virtual/kernel
grep CONFIG_WIREGUARD .config
```

---

## Additional Resources

- [Yocto Kernel Development](https://docs.yoctoproject.org/kernel-dev/)
- [Raspberry Pi Kernel](https://github.com/raspberrypi/linux)
- [KSPP Recommendations](https://kspp.github.io/)
- [Linux Kernel Configuration](https://www.kernel.org/doc/html/latest/admin-guide/README.html)
