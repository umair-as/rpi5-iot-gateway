# Kernel Configuration

This document describes the kernel configuration system and available feature sets.

## Overview

The distribution uses **modular kernel configuration** based on feature fragments.

**Default kernel provider:** `linux-iotgw-mainline` (Linux 6.18 series)

**FIT flow provider:** `linux-iotgw-mainline-fit` (Linux 6.18 series)

**Always Enabled:**
- `branding.cfg` — Kernel version suffix (`-v8-16k-igw`)
- `trim.cfg` — disable non-required subsystems for appliance profile
- `storage-filesystems.cfg` — OverlayFS, dm-verity, SquashFS (required for RAUC)
- `ikconfig.cfg` — runtime kernel config introspection support
- `audit.cfg` — audit framework plumbing
- `panic-recovery.cfg` — kernel-baked panic posture: `CONFIG_PANIC_TIMEOUT=30`
  + `CONFIG_BOOTPARAM_PANIC_ON_OOPS=y`. Any oops escalates to panic, panic
  reboots within 30s — applies from the first instruction the kernel runs,
  before userspace, before sysctl, before watchdog drivers probe. Closes
  the early-boot "kernel hangs requiring power cycle" failure class.
- `rtc-rpi.cfg` — Raspberry Pi RTC support (gated by `IOTGW_ENABLE_RPI_RTC`)

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
# Confirm eBPF kernel plumbing is available (installed by default in dev images)
bpftool feature probe kernel

# Inspect loaded BPF programs and maps
bpftool prog show
bpftool map show

# Function tracing
echo function > /sys/kernel/debug/tracing/current_tracer
cat /sys/kernel/debug/tracing/trace
```

---

### `igw_pstore_persist`

Kernel pstore RAM backend for persisting oops/panic state across reboot.
**Production-safe; on by default in all images.**

This is the *capture infrastructure* — no behavior change at runtime, just
ensures that when the kernel does crash, the post-mortem evidence survives
the reboot. Pairs with the systemd hardware watchdog so a stuck-kernel
event becomes a watchdog reset → record landing on `/data` → recoverable
unit on next boot.

**Features (kernel):**
- `CONFIG_PSTORE`, `CONFIG_PSTORE_RAM`, `CONFIG_PSTORE_CONSOLE`,
  `CONFIG_PSTORE_PMSG`

Reboot-on-panic semantics live in the always-applied `panic-recovery.cfg`
fragment, not here — pstore is the post-mortem capture stack, panic
recovery is the system-wide reboot policy. They're orthogonal: pstore can
be disabled without losing panic recovery, and vice versa.

**BSP wiring (RPi5):** patch
`0007-arm64-dts-broadcom-bcm2712-rpi-5-b-add-ramoops-reserved-memory.patch`
reserves a 1 MiB region at `0x13000000` and binds a `compatible = "ramoops"`
node to it. The patch is gated on the same toggle.

**Userspace wiring:**
- `systemd` is built with the `pstore` PACKAGECONFIG, so PID1 ships
  `systemd-pstore.service`.
- The `iotgw-pstore-persist` recipe ships
  `var-lib-systemd-pstore.mount` (a systemd `.mount` unit, not a helper
  service) which bind-mounts `/data/crash/pstore` onto
  `/var/lib/systemd/pstore`. PID1 performs the mount, so it is host-visible
  before `systemd-pstore.service` runs and writes records.
- `systemd-pstore.service` gets a drop-in adding
  `RequiresMountsFor=/var/lib/systemd/pstore`, which auto-orders it after
  the bind mount.
- A `tmpfiles.d` entry creates `/data/crash/pstore` on first boot.
- `iotgw-pstore-prune.service` enforces retention by file count and total
  bytes (defaults `IOTGW_PSTORE_MAX_FILES=20`, `IOTGW_PSTORE_MAX_BYTES=100M`)
  and `xz`-compresses older records to keep the archive bounded.

**Layer gate:** `IOTGW_ENABLE_PSTORE_PERSIST` (default `"1"`). The feature
token is auto-appended to `IOTGW_KERNEL_FEATURES`; you do not normally list
it explicitly.

**Verification on target:**
```bash
# Reserved memory + ramoops registration
dmesg | grep -E "reserved mem.*ramoops|pstore: Registered ramoops"

# Bind mount visible to PID1
findmnt /var/lib/systemd/pstore   # SOURCE should be /data/crash/pstore

# Trigger a panic (lab only — requires sysrq, see igw_crash_debug_dev)
echo c > /proc/sysrq-trigger
# After reboot:
ls /data/crash/pstore/            # console-ramoops-0, dmesg-ramoops-0, …
```

---

### `igw_crash_debug_dev`

**Aggressive lab-only debug** layered on top of `igw_pstore_persist`. Adds
runtime detectors and kernel knobs that turn recoverable conditions into
deterministic panics — useful in a debug campaign, **unsafe for fleet
deployments**.

**Features (kernel):**
- `CONFIG_PSTORE_FTRACE` — function tracing into pstore for post-mortem
  trace replay
- `CONFIG_DYNAMIC_DEBUG`, `CONFIG_DYNAMIC_DEBUG_CORE` — runtime
  pr_debug enablement via `/sys/kernel/debug/dynamic_debug/control`
- `CONFIG_MAGIC_SYSRQ` — kernel control surface (security-relevant)
- `CONFIG_DETECT_HUNG_TASK`, `CONFIG_SOFTLOCKUP_DETECTOR`
- `CONFIG_HARDLOCKUP_DETECTOR` is intentionally **not** set — backend
  support varies per platform/watchdog

**Userspace wiring:**
- `iotgw-crash-debug-sysctl` drops `/etc/sysctl.d/95-iotgw-crash-debug.conf`:
  `kernel.panic = ${IOTGW_CRASH_PANIC_TIMEOUT}`,
  `kernel.panic_on_oops = 1`, `kernel.sysrq = 1`.
- `rpi-cmdline.bbappend` appends to the kernel command line:
  `panic=${IOTGW_CRASH_PANIC_TIMEOUT} oops=panic sysrq_always_enabled=1`
  (the cmdline value governs the kernel-phase panic timeout before
  `sysctl.d` applies; both are driven by the same variable).

**Layer gates:**
- `IOTGW_ENABLE_CRASH_DEBUG_DEV` (default `"0"`) — opt-in.
  Setting this to `"1"` implies `IOTGW_ENABLE_PSTORE_PERSIST=1`.
- `IOTGW_CRASH_PANIC_TIMEOUT` (default `"5"`) — seconds.

**What ships where:**

| Component | prod default | dev (`IOTGW_ENABLE_CRASH_DEBUG_DEV=1`) |
|---|:-:|:-:|
| DT ramoops reserved-memory patch | ✓ | ✓ |
| Kernel `PSTORE` family (RAM/CONSOLE/PMSG) | ✓ | ✓ |
| `systemd` `pstore` PACKAGECONFIG + `systemd-pstore.service` | ✓ | ✓ |
| `iotgw-pstore-persist` (`.mount` + tmpfiles + prune) | ✓ | ✓ |
| `CONFIG_DYNAMIC_DEBUG`, `MAGIC_SYSRQ`, `DETECT_HUNG_TASK`, `SOFTLOCKUP_DETECTOR`, `PSTORE_FTRACE` | ✗ | ✓ |
| `iotgw-crash-debug-sysctl` (panic/oops/sysrq sysctls) | ✗ | ✓ |
| Cmdline `panic= oops=panic sysrq_always_enabled=1` | ✗ | ✓ |

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

**See:** [SECURITY.md](SECURITY.md) for full details

---

### `igw_tpm_slb9672`

TPM2 baseline for SPI-attached Infineon SLB9672 class devices.

**Features:** Built-in (`=y`) TPM core/TIS/TIS-SPI stack and SPI host path.

**Developer note:** `SPI_SPIDEV` is intentionally left commented in the
fragment. Avoid enabling spidev on the same SPI chip-select used by TPM.

**Runtime wiring:** enabling `IOTGW_ENABLE_TPM_SLB9672 = "1"` appends:
- `dtoverlay=${IOTGW_TPM_DTO_OVERLAY}` (default `tpm-slb9670`)

If board wiring requires a different overlay parameterization, override
`IOTGW_TPM_DTO_OVERLAY` in `kas/local.yml`.

**Mainline RPi5 note (important):**
- `dtparam=` keys work only when exported in DTB `__overrides__`.
- On our current mainline `bcm2712-rpi-5-b.dtb`, classic keys such as
  `spi`, `i2c1`, and `i2c_arm` are not exported, so firmware logs
  `Unknown dtparam ... - ignored`.
- Use explicit `dtoverlay=` and DTS changes for peripheral enablement on
  this path instead of relying on generic `ENABLE_SPI_BUS`/`ENABLE_I2C`.
- `dtparam=rtc_bbat_vchg=...` is valid here because the RTC overlay exports it.

**TPM reset via GPIO (dev only):** If the TPM enters a bad state during
development, toggle the reset pin (GPIO 24 on LetsTrust-style wiring):
```bash
pinctrl set 24 op && pinctrl set 24 dl && sleep 0.1 && pinctrl set 24 dh
tpm2_startup -c
```

---

### `igw_no_efi`

Opt-in kernel EFI surface reduction for non-UEFI Raspberry Pi boot flow.

**Features:** disables EFI runtime/stub/efivar paths in the kernel build.

**Use for:** appliance deployments that boot via Raspberry Pi firmware + U-Boot
`bootm` flow and do not require kernel EFI interfaces.

**Important:** this feature intentionally does **not** disable
`CONFIG_EFI_PARTITION`, since GPT partition parsing relies on it.

**Layer gate:** `IOTGW_ENABLE_KERNEL_NO_EFI` (defaults to `1`).

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

### RTC Backport Gate (Mainline Providers)

Raspberry Pi firmware RTC backport can be toggled with:

```yaml
local_conf_header:
  rtc_gate: |
    IOTGW_ENABLE_RPI_RTC = "1"   # set to "0" to disable rtc-rpi patch/fragment
```

### Raspberry Pi EEPROM / VCIO Gate

Enable/disable EEPROM maintenance tooling and VCIO carry patch:

```yaml
local_conf_header:
  rpi_eeprom_gate: |
    IOTGW_ENABLE_RPI_EEPROM = "1"  # set to "0" to exclude rpi-eeprom tooling packages
    IOTGW_ENABLE_VCIO = "1"        # default follows IOTGW_ENABLE_RPI_EEPROM
```

### TPM SPI Gate

Enable TPM2-over-SPI profile and firmware overlay:

```yaml
local_conf_header:
  tpm_spi: |
    IOTGW_ENABLE_TPM_SLB9672 = "1"
    # Optional override (default "tpm-slb9670")
    # IOTGW_TPM_DTO_OVERLAY = "tpm-slb9670"
```

### Kernel EFI Surface Gate

Enable/disable EFI surface reduction fragment:

```yaml
local_conf_header:
  kernel_efi_gate: |
    IOTGW_ENABLE_KERNEL_NO_EFI = "1"   # set to "0" to keep kernel EFI options enabled
```

## DTB Selection

For `MACHINE = "raspberrypi5"`, DTB packaging follows `RPI_KERNEL_DEVICETREE` policy:

- Default: ship only `bcm2712-rpi-5-b.dtb` (Pi 5 Model B focused build)
- Optional: include CM5 DTBs for shared/fleet images

Enable CM5 DTBs in `kas/local.yml` (or product config):

```yaml
local_conf_header:
  dtb_policy: |
    IOTGW_RPI5_INCLUDE_CM5_DTBS = "1"
```

Runtime checks on target:

```bash
cat /proc/device-tree/model
cat /proc/device-tree/compatible | tr '\0' '\n'
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

---

## Additional Resources

- [Yocto Kernel Development](https://docs.yoctoproject.org/kernel-dev/)
- [Linux Stable Kernel](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git)
- [Raspberry Pi Kernel (alternative provider path)](https://github.com/raspberrypi/linux)
- [KSPP Recommendations](https://kspp.github.io/)
- [Linux Kernel Configuration](https://www.kernel.org/doc/html/latest/admin-guide/README.html)
