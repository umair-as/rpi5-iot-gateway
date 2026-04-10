# LSM and IMA Exploration Notes

Practical field notes from bringing up SELinux, AppArmor, and IMA on the RPi5 IoT Gateway.
Covers concepts, observed behaviour on target, and annotated commands with their actual output.

**Branch:** `feat/selinux-ima-apparmor`
**Kernel:** `6.18.13-v8-16k-igw` (RPi5 downstream, Scarthgap build)
**Date:** 2026-04-10

---

## Table of Contents

1. [LSM — Linux Security Modules](#1-lsm--linux-security-modules)
2. [AppArmor](#2-apparmor)
3. [SELinux](#3-selinux)
4. [IMA — Integrity Measurement Architecture](#4-ima--integrity-measurement-architecture)
5. [TPM Interaction with IMA](#5-tpm-interaction-with-ima)
6. [Target Command Reference](#6-target-command-reference)
7. [Known Issues / Open Items](#7-known-issues--open-items)

---

## 1. LSM — Linux Security Modules

### What it is

The Linux kernel has a hook-based framework called LSM (Linux Security Modules) that allows
security subsystems to intercept kernel operations — file open, process exec, socket connect,
capability checks — and apply their own policy. Multiple LSMs can be compiled in, but only
one "major" MAC (Mandatory Access Control) LSM can be active as the enforcing system at a time.

Two categories:

| Category | LSMs | Notes |
|----------|------|-------|
| Always-on (minor) | `capability`, `lockdown`, `yama`, `ima` | Always initialised, not exclusive |
| MAC (exclusive) | `apparmor`, `selinux`, `smack`, `tomoyo` | Only one can hold the exclusive slot |

### CONFIG_LSM — the critical string

`CONFIG_SECURITY_SELINUX=y` compiles SELinux into the kernel but does **not** initialise it.
`CONFIG_LSM` controls which LSMs are initialised at boot and in what order:

```
CONFIG_LSM="lockdown,yama,apparmor,selinux"
```

Without an LSM in this string it is compiled in but completely dormant.

### LSM_FLAG_EXCLUSIVE — why only one MAC runs

Both AppArmor and SELinux carry `LSM_FLAG_EXCLUSIVE` in their kernel registration. The kernel's
`ordered_lsm_init()` enforces a single exclusive slot:

1. Processes `CONFIG_LSM` left to right
2. First exclusive LSM encountered claims the slot → initialised
3. Second exclusive LSM → slot already taken → **silently skipped**

With `CONFIG_LSM="lockdown,yama,apparmor,selinux"`:

```
lockdown  → not exclusive → initialised
yama      → not exclusive → initialised
apparmor  → EXCLUSIVE → claims slot → initialised  ✓
selinux   → EXCLUSIVE → slot taken  → skipped       ✗
```

This is **by design** — both are compiled in, AppArmor is the default because it is listed first.
SELinux is dormant but ready: switch it on at runtime via the `lsm=` cmdline parameter, which
replaces `CONFIG_LSM` entirely for that boot.

### Actual boot output (kernel dmesg)

```
[    0.000201] LSM: initializing lsm=capability,lockdown,yama,apparmor,ima
[    0.000323] AppArmor: AppArmor initialized
[    0.076758] AppArmor: AppArmor Filesystem Enabled
[    0.168083] ima: No TPM chip found, activating TPM-bypass!
[    0.168085] ima: Allocated hash algorithm: sha256
[    0.168100] ima: No architecture policies found
```

Note: `ima` appears in the runtime list even though it is not in `CONFIG_LSM` — IMA is a
minor LSM added to the init list automatically by the kernel regardless of that string.
`selinux` does not appear because it lost the exclusive slot to AppArmor.

### Verifying the active LSM stack at runtime

```bash
# Active LSMs (what actually initialised)
cat /sys/kernel/security/lsm
# Actual output on our target:
# capability,lockdown,yama,apparmor,ima

# LSM-specific sysfs directories (only present when active)
ls /sys/kernel/security/
# Output: apparmor  ima  lockdown

# SELinux filesystem — only mounted if SELinux is the active MAC
ls /sys/fs/selinux/
# Output: ls: cannot access '/sys/fs/selinux': No such file or directory
# (expected — AppArmor is the active MAC, not SELinux)
```

### Switching the MAC LSM at runtime (without rebuild)

`lsm=` on the kernel cmdline replaces `CONFIG_LSM` for that boot. Non-exclusive LSMs
(capability, yama, lockdown, ima) are still loaded via the unordered path.

```bash
# Activate SELinux as the MAC at next boot:
fw_setenv EXTRA_KERNEL_ARGS 'lsm=selinux'

# Revert to AppArmor (default):
fw_setenv EXTRA_KERNEL_ARGS ''

# Verify current cmdline:
cat /proc/cmdline
```

**Prerequisite before switching to SELinux:** SELinux userspace must be present —
`policycoreutils`, `libselinux`, and a base policy (`meta-selinux` layer). Without a
policy loaded, SELinux will operate in enforcing mode with no rules and will likely
block everything.

---

## 2. AppArmor

### What it does

AppArmor is a path-based MAC system. It confines processes using *profiles* — each profile
specifies what files, capabilities, and network operations a process is allowed. A process
running under a profile that does not permit an operation gets denied; without a profile,
the process runs *unconfined* (no restriction from AppArmor).

### What we observed on target

```bash
aa-status
# apparmor module is loaded.
# 60 profiles are loaded.
# 60 profiles are in complain mode.
# 0 profiles are in enforce mode.
# 0 processes have profiles defined.
# 0 processes are in enforce mode.
# 0 processes are in complain mode.
# 0 processes are unconfined but have a profile defined.
```

All 60 profiles are upstream defaults for services like apache2, dovecot, cups, php-fpm —
none of which run on this gateway. All IoT gateway processes are **unconfined**.

In dmesg these load as:
```
[    2.525053] audit: type=1400 ... apparmor="STATUS" operation="profile_load" name="lsb_release"
[    2.573291] audit: type=1400 ... apparmor="STATUS" operation="profile_load" name="ping"
[    2.603419] audit: type=1400 ... apparmor="STATUS" operation="profile_load" name="nvidia_modprobe"
[    2.643125] audit: type=1400 ... apparmor="STATUS" operation="profile_load" name="samba-bgqd"
...
```

**Key insight:** AppArmor provides no protection until custom profiles exist for the
binaries you care about. Loading 60 irrelevant profiles in `complain` mode is pure overhead.

### Boot overhead

```
apparmor.service  ~2.5s
```

Cost of loading 60 upstream profiles. Purpose-built minimal profiles would be much lighter
but require significant policy authoring effort.

### Checking individual process confinement

```bash
# Check confinement of a running process
cat /proc/$(pgrep NetworkManager)/attr/current
# "unconfined" means no AppArmor profile applied

# Via aa-status (lists all confined processes)
aa-status
```

### AppArmor kernel config — fragment comment vs kconfig directive

Our `security-prod.cfg` contains:
```
# CONFIG_SECURITY_APPARMOR=y
# CONFIG_DEFAULT_SECURITY_APPARMOR=y
```

These are **comments**, not kconfig directives. The RPi base kernel config has AppArmor
enabled, and our fragment comments do not disable it. To actually disable a config option
via a `.cfg` fragment the syntax must be:

```
# CONFIG_SECURITY_APPARMOR is not set
```

AppArmor is enabled on this build (`CONFIG_SECURITY_APPARMOR=y` visible in `/proc/config.gz`).
This is intentional — AppArmor is the current default MAC while SELinux userspace is pending.

Confirmed on target:
```bash
zcat /proc/config.gz | grep CONFIG_SECURITY_APPARMOR
# CONFIG_SECURITY_APPARMOR=y
# CONFIG_SECURITY_APPARMOR_INTROSPECT_POLICY=y
# CONFIG_SECURITY_APPARMOR_HASH=y
# CONFIG_SECURITY_APPARMOR_HASH_DEFAULT=y
# CONFIG_SECURITY_APPARMOR_EXPORT_BINARY=y
# CONFIG_SECURITY_APPARMOR_PARANOID_LOAD=y
```

---

## 3. SELinux

### What it does

SELinux is a label-based MAC system. Every object (file, socket, process, device) gets a
*security context* (`user:role:type:level`). Policy rules define what types can interact.
More expressive than path-based AppArmor, but also significantly more complex to write
policy for.

**Two enforcement modes:**
- `permissive` — logs all denials, enforces nothing. Safe for policy development.
- `enforcing` — denials are blocked. Production mode.

**Per-domain permissive** (`CONFIG_SECURITY_SELINUX_DEVELOP=y`): individual domains can
be set permissive while the rest enforce. Useful for incremental policy bring-up.

### Current state after rebuild (2026-04-10)

```bash
zcat /proc/config.gz | grep -E 'CONFIG_LSM=|CONFIG_SECURITY_SELINUX'
# CONFIG_SECURITY_SELINUX=y
# # CONFIG_SECURITY_SELINUX_BOOTPARAM is not set
# CONFIG_SECURITY_SELINUX_DEVELOP=y
# CONFIG_SECURITY_SELINUX_AVC_STATS=y
# CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9
# CONFIG_SECURITY_SELINUX_SID2STR_CACHE_SIZE=256
# CONFIG_LSM="lockdown,yama,apparmor,selinux"
```

SELinux is compiled in — confirmed by kernel symbol count:
```bash
grep -c selinux /proc/kallsyms
# 273
```

But it is **not initialised** because AppArmor claimed the exclusive MAC slot first
(see section 1). No SELinux messages in dmesg. `/sys/fs/selinux` does not exist.

Also note: `systemd` on this image is built without SELinux or AppArmor userspace bindings:
```
systemd[1]: systemd 255.21 running in system mode (-PAM +AUDIT -SELINUX -APPARMOR +IMA ...)
```
The `-SELINUX -APPARMOR` flags are **systemd compile-time flags**, not kernel state.
They indicate systemd was not linked against `libselinux` or `libapparmor`. The kernel
AppArmor LSM is still active and functional — systemd just doesn't call the library hooks.

### SELinux kernel config (`selinux.cfg`)

```
CONFIG_SECURITY_SELINUX=y
# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set   ← no selinux=0 cmdline escape
CONFIG_SECURITY_SELINUX_DEVELOP=y                 ← per-domain permissive for policy dev
CONFIG_SECURITY_SELINUX_AVC_STATS=y               ← AVC cache hit/miss stats
CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9        ← SID table size (512 buckets)
CONFIG_SECURITY_SELINUX_SID2STR_CACHE_SIZE=256    ← label string cache entries
CONFIG_LSM="lockdown,yama,apparmor,selinux"       ← adds selinux to the candidate list
```

### Why `BOOTPARAM` is disabled

`CONFIG_SECURITY_SELINUX_BOOTPARAM=y` would allow `selinux=0` on the kernel cmdline to
disable SELinux at boot. Kept off so the compiled-in state is deterministic and cannot be
silently bypassed. Since SELinux is not currently the active MAC anyway, this is moot
for now but is the right posture for when it becomes the default.

### Path to activating SELinux

Prerequisites before using `lsm=selinux`:
1. `meta-selinux` layer integrated (provides `policycoreutils`, `libselinux`, `checkpolicy`)
2. Base SELinux policy compiled and installed to `/etc/selinux/`
3. Filesystem labelling run at first boot or during image build (`fixfiles` / `setfiles`)
4. Start with `enforcing=0` (permissive) to collect AVC denials before enforcing

```bash
# Once prerequisites are met, activate SELinux at next boot:
fw_setenv EXTRA_KERNEL_ARGS 'lsm=selinux enforcing=0'

# Check AVC denials:
ausearch -m AVC -ts recent

# getenforce/setenforce (requires policycoreutils):
getenforce
setenforce 0   # permissive
setenforce 1   # enforcing
```

---

## 4. IMA — Integrity Measurement Architecture

### What it is

IMA (Integrity Measurement Architecture) is a kernel subsystem that creates a cryptographic
log of every file opened for execution or reading by a privileged process. This log can be:

1. **Extended into a TPM PCR** (PCR10 by default) — the accumulated hash of everything that
   ran is sealed in hardware. Tampering with files that executed since boot changes PCR10
   and will fail a TPM policy sealing to that PCR.

2. **Queried from userspace** — via the measurement log at
   `/sys/kernel/security/ima/ascii_runtime_measurements`.

### Two modes: measure vs appraise

| Mode | What it does | Requires |
|------|-------------|---------|
| **measure** | SHA256 of executed files logged to IMA + extends PCR10 | Nothing — any binary works |
| **appraise** | Verifies `security.ima` xattr on each file before exec | Signed xattrs set at build time with `evmctl` |

**Our current config is measure-only** (`CONFIG_IMA_APPRAISE` is not set).

In measure-only mode:
- Every binary executed is hashed and logged
- Nothing is blocked — a tampered binary still runs
- PCR10 accumulates the measurement log hash (blocked on RPi5 by SPI ordering — see section 5)
- `ima_inspect` returns "No such attribute" — correct, no xattrs are set in measure-only mode

In appraise mode:
- Kernel reads `security.ima` xattr before executing any file
- Xattr contains a signed hash of the file's content from build time
- Hash mismatch or missing xattr → exec blocked (with `imasig` policy)
- **This is what actually prevents tampered binaries from running**

Measure-only is safe to enable with zero build preparation, provides audit trail, but does
not block anything. Appraise requires all shipped binaries to carry signed xattrs — a
significant investment in build infrastructure (signing keys, recipe integration, evmctl).

### IMA policy — TCB

IMA behaviour is controlled by a *policy* specifying which files to measure/appraise.

**Built-in policies (kernel cmdline):**

| Policy | Effect |
|--------|--------|
| `ima_policy=tcb` | Measure all exec, kernel modules, firmware, and root reads |
| `ima_policy=appraise_tcb` | Same as tcb but also appraises (requires xattrs) |
| `ima_policy=secure_boot` | Module and firmware appraisal only |

**`ima_policy=exec` is not valid** — caused `ima: policy "exec" not found` at boot.
Valid names are `tcb`, `appraise_tcb`, `secure_boot` (kernel version-dependent).

**Active on our target** (`ima_policy=tcb` set via U-Boot env):

```bash
cat /sys/kernel/security/ima/policy
# dont_measure fsmagic=0x9fa0        ← procfs
# dont_measure fsmagic=0x62656572    ← selinuxfs
# dont_measure fsmagic=0x64626720    ← debugfs
# dont_measure func=FILE_CHECK fsmagic=0x1021994  ← tmpfs
# dont_measure fsmagic=0x1cd1        ← binfmt_misc
# dont_measure fsmagic=0x42494e4d    ← binfmtfs
# dont_measure fsmagic=0x73636673    ← securityfs
# dont_measure fsmagic=0xf97cff8c    ← sockfs
# dont_measure fsmagic=0x43415d53    ← tracefs
# dont_measure fsmagic=0x27e0eb      ← cgroupfs
# ... (measures everything else)
```

The `dont_measure` rules exclude pseudo-filesystems from the log. Everything on real
storage (rootfs, /data, kernel modules) is measured.

### Confirmed working on target

```bash
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
# 895 /sys/kernel/security/ima/ascii_runtime_measurements
```

895 files measured since boot. IMA is actively logging all executed files.

### IMA kernel config (`ima.cfg`)

```
CONFIG_IMA=y
CONFIG_IMA_MEASURE_PCR_IDX=10          ← standard IMA PCR slot (do not change)
CONFIG_IMA_LSM_RULES=y                  ← IMA policy can reference LSM labels
CONFIG_IMA_NG_TEMPLATE=y               ← modern template (filename + hash in log)
CONFIG_IMA_DEFAULT_TEMPLATE="ima-ng"   ← use ng template
CONFIG_IMA_DEFAULT_HASH_SHA256=y       ← SHA256 (not SHA1)
CONFIG_IMA_DEFAULT_HASH="sha256"
CONFIG_IMA_READ_POLICY=y               ← userspace can read active policy
# CONFIG_IMA_APPRAISE is not set       ← measure-only; no xattr verification
CONFIG_IMA_MEASURE_ASYMMETRIC_KEYS=y  ← key loads affect measurement log
CONFIG_IMA_QUEUE_EARLY_BOOT_KEYS=y    ← queue key ops before IMA ready
CONFIG_CRYPTO_SHA1=y                   ← required for IMA internals even with SHA256
```

### IMA log entry format

```
10 <pcr-template-hash> ima-ng sha256:<file-hash> <filename>
│                               │                 │
│                               │                 file path measured
│                               SHA256 of file content
PCR index (always 10)
```

### `ima_inspect` — checking appraisal xattrs

`ima_inspect` (binary name uses underscore: `ima_inspect`) reads `security.ima` extended
attributes. Only relevant in appraise mode.

```bash
ima_inspect /usr/bin/tpm-ops
# ima_inspect: security.ima: No such attribute
```

This is correct in measure-only mode — no xattrs are set, so there is nothing to inspect.
The file is still being *measured* (hashed and logged on exec); it is just not *appraised*
(signature-verified before exec).

### `evmctl` — reading the measurement log

`evmctl` (from `ima-evm-utils`) is the main IMA/EVM userspace tool:

```bash
evmctl ima_measurement /sys/kernel/security/ima/binary_runtime_measurements
# error: tsspcrread: command not found
```

`evmctl` uses `tsspcrread` from the IBM TSS library to read PCR values. Our image
uses `tpm2-tools` / `tpm-ops` (TSS2), not IBM TSS. Use `tpm2_pcrread` instead:

```bash
tpm2_pcrread sha256:10
# sha256:
#   10: 0x0000000000000000000000000000000000000000000000000000000000000000
```

---

## 5. TPM Interaction with IMA

### How it is supposed to work

1. Kernel boots, IMA subsystem initialises early
2. IMA measures every file it is configured to measure (exec, module loads, etc.)
3. Each measurement calls `tpm_pcr_extend(10, sha256(event))` → PCR10 accumulates
4. By userspace, PCR10 = hash of everything that ran since boot
5. Attestation: TPM quote on PCR10 proves what ran on this device

### What actually happens on RPi5

The SLB9672 TPM is connected via SPI over the RP1 south-bridge. The RP1 SPI controller
comes up *after* IMA initialises early in boot:

```
[early boot] IMA init → tries tpm_pcr_extend → TPM not ready → BYPASS activated
[later boot] RP1 SPI ready → /dev/tpm0, /dev/tpmrm0 appear → IMA already finished
```

Confirmed in dmesg:
```
[    0.168083] ima: No TPM chip found, activating TPM-bypass!
```

Result: IMA log is populated (895 entries), but PCR10 is all zeros. Remote attestation
based on PCR10 is not feasible in the current boot topology.

### All PCRs on target

```bash
tpm2_pcrread sha256
# sha256:
#   0 : 0x000000000000...  ← no UEFI measured boot (U-Boot → FIT → kernel)
#   1 : 0x000000000000...
#   ...
#   10: 0x000000000000...  ← IMA TPM-bypass (SPI not ready at IMA init)
#   11-23: 0x000000000000...
```

All zero. RPi5 has no UEFI firmware measured boot chain, so PCR 0–7 are never extended
by firmware. PCR10 is never extended due to the SPI ordering constraint.

### Path forward for PCR sealing

None implemented. Options for future work:

1. **Initramfs extend** — early-boot script reads IMA log and manually extends a PCR after
   TPM becomes reachable. Requires custom initramfs with tpm2-tools inside.
2. **U-Boot TPM extend** — U-Boot extends PCRs for FIT blob hashes. RP1 SPI problem exists
   at U-Boot stage too (parked — see WORKBOARD).
3. **OS-managed PCR** — Seal keys to a PCR the OS controls (e.g. PCR7), rather than relying
   on firmware measured boot.
4. **Software-only audit** — Use IMA log for forensics without TPM sealing. Tamper-evident
   (you can detect tampering post-incident) but not tamper-proof at runtime.

---

## 6. Target Command Reference

All commands run as root on `iotgw` via SSH after the second OTA on `feat/selinux-ima-apparmor`.

### LSM stack

```bash
# What LSMs are actually initialised
cat /sys/kernel/security/lsm
# capability,lockdown,yama,apparmor,ima

# LSM sysfs directories (one per active LSM)
ls /sys/kernel/security/
# apparmor  ima  lockdown

# Is SELinux filesystem mounted?
ls /sys/fs/selinux/
# ls: cannot access '/sys/fs/selinux': No such file or directory
# (expected — AppArmor holds the exclusive MAC slot)

# Verify what CONFIG_LSM was compiled with
zcat /proc/config.gz | grep CONFIG_LSM=
# CONFIG_LSM="lockdown,yama,apparmor,selinux"

# Count SELinux symbols (proves code is compiled in even though not initialised)
grep -c selinux /proc/kallsyms
# 273
```

### SELinux and AppArmor config on target

```bash
zcat /proc/config.gz | grep -E 'CONFIG_LSM=|CONFIG_SECURITY_SELINUX|CONFIG_SECURITY_APPARMOR|SELINUX_DISABLE|DEFAULT_SECURITY|NETLABEL|NETWORK_SECMARK'
# # CONFIG_NETLABEL is not set           ← NETLABEL not set (SELinux network labelling)
# CONFIG_NETWORK_SECMARK=y
# # CONFIG_DEFAULT_SECURITY_SELINUX is not set
# CONFIG_DEFAULT_SECURITY_APPARMOR=y
# CONFIG_LSM="lockdown,yama,apparmor,selinux"
# CONFIG_SECURITY_SELINUX=y
# # CONFIG_SECURITY_SELINUX_BOOTPARAM is not set
# CONFIG_SECURITY_SELINUX_DEVELOP=y
# CONFIG_SECURITY_SELINUX_AVC_STATS=y
# CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9
# CONFIG_SECURITY_SELINUX_SID2STR_CACHE_SIZE=256
# CONFIG_SECURITY_APPARMOR=y
```

### AppArmor

```bash
# Status summary
aa-status
# apparmor module is loaded.
# 60 profiles are loaded.
# 60 profiles are in complain mode.
# 0 profiles are in enforce mode.
# 0 processes have profiles defined.

# Check confinement status of a specific process
cat /proc/$(pgrep NetworkManager)/attr/current
# "unconfined"
```

### IMA measurement log

```bash
# IMA sysfs directory
ls /sys/kernel/security/ima/
# ascii_runtime_measurements  binary_runtime_measurements  policy  violations

# How many files measured since boot
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
# 895

# Active policy (tcb rules — dont_measure pseudo-fs, measure everything else)
cat /sys/kernel/security/ima/policy
# dont_measure fsmagic=0x9fa0
# dont_measure fsmagic=0x62656572
# ... (excludes pseudo-filesystems)

# Last few measured entries
tail -5 /sys/kernel/security/ima/ascii_runtime_measurements

# Check if a specific binary was measured
grep tpm-ops /sys/kernel/security/ima/ascii_runtime_measurements

# Binary log size (non-zero confirms IMA is active)
ls -lh /sys/kernel/security/ima/binary_runtime_measurements
```

### IMA appraisal xattrs

```bash
# Check for appraisal xattr (measure-only: always "No such attribute")
ima_inspect /usr/bin/tpm-ops
# ima_inspect: security.ima: No such attribute

# Same check via getfattr
getfattr -n security.ima /usr/bin/tpm-ops
# No such attribute
```

### TPM / PCR state

```bash
# All PCRs — all zero on RPi5 (no measured boot chain)
tpm2_pcrread sha256

# PCR10 specifically (IMA PCR — zero due to TPM-bypass at IMA init)
tpm2_pcrread sha256:10
# sha256:
#   10: 0x0000000000000000000000000000000000000000000000000000000000000000

# TPM reachable?
tpm-ops info
tpm-ops pcr-read
```

### Kernel cmdline

```bash
# Current cmdline (shows ima_policy=tcb if set)
cat /proc/cmdline
# ... ima_policy=tcb

# U-Boot env var driving extra kernel args
fw_printenv EXTRA_KERNEL_ARGS
# EXTRA_KERNEL_ARGS=ima_policy=tcb

# Set IMA policy for next boot
fw_setenv EXTRA_KERNEL_ARGS 'ima_policy=tcb'

# Add SELinux activation alongside IMA policy
fw_setenv EXTRA_KERNEL_ARGS 'ima_policy=tcb lsm=selinux enforcing=0'

# Clear extra args
fw_setenv EXTRA_KERNEL_ARGS ''
```

### Kernel config spot-checks

```bash
# IMA compiled in?
zcat /proc/config.gz | grep 'CONFIG_IMA[^_]'
# CONFIG_IMA=y

# LSM init string
zcat /proc/config.gz | grep CONFIG_LSM=
# CONFIG_LSM="lockdown,yama,apparmor,selinux"

# SELinux and its deps
zcat /proc/config.gz | grep -E 'SELINUX|NETLABEL|SECURITY_NETWORK'
```

### Boot time (security units)

```bash
systemd-analyze blame | grep -E 'apparmor|audit|ima|selinux'
# apparmor.service   ~2.5s  (loading 60 upstream profiles)
```

---

## 7. Known Issues / Open Items

### SELinux skipped by exclusive LSM slot (by design, not a bug)

SELinux is compiled in and present in `CONFIG_LSM`. It does not initialise because AppArmor
claims the exclusive MAC slot first (AppArmor is listed before selinux in the string).

**To activate SELinux:** `fw_setenv EXTRA_KERNEL_ARGS 'lsm=selinux enforcing=0'`

**Prerequisite:** `meta-selinux` layer + base policy must be integrated first.

### IMA TPM PCR10 always zero (hardware constraint)

SPI-attached SLB9672 comes up after IMA kernel subsystem initialises. TPM-bypass active.
PCR10 remains zero. IMA log is populated and readable; TPM sealing is not.
No fix in the current boot topology.

### `CONFIG_NETLABEL` not auto-selected

`CONFIG_SECURITY_SELINUX=y` + `CONFIG_NETWORK_SECMARK=y` should trigger
`select NETLABEL` via Kconfig, but the built config shows `# CONFIG_NETLABEL is not set`.
This is a fragment/Kconfig interaction issue. SELinux network labelling (`netlabel`) is
not available; standard socket-based SELinux policy still works without it.

### Fragment comment does not disable a config option

In `security-prod.cfg`:
```
# CONFIG_SECURITY_APPARMOR=y      ← just a comment, does NOT disable AppArmor
```

To disable a config option via a `.cfg` fragment:
```
# CONFIG_SECURITY_APPARMOR is not set
```

AppArmor is intentionally left enabled (it is the current default MAC). This is noted
here so the syntax distinction is clear for future fragment authors.

### `systemd-machine-id-commit.service` failing (tracked in WORKBOARD)

`iotgw-machine-id.service` writes a real file to overlayfs. The commit service fails because
machine-id is not on a transient filesystem. Fix: mask the unit in the image.

### AppArmor 60 upstream profiles, ~2.5s boot overhead

All 60 profiles are irrelevant to the gateway workload. For production either write
purpose-built profiles or switch to SELinux.

### `evmctl ima_measurement` fails (IBM TSS missing)

`evmctl` requires `tsspcrread` from IBM TSS. Image uses TSS2 (`tpm2-tools` / `tpm-ops`).
Use `tpm2_pcrread sha256:10` as the equivalent PCR read command.

---

## References

- [IMA kernel docs](https://www.kernel.org/doc/html/latest/security/IMA-templates.html)
- [IMA Wiki](https://sourceforge.net/p/linux-ima/wiki/Home/)
- [KSPP recommended settings](https://kspp.github.io/Recommended_Settings.html)
- [SELinux Notebook](https://github.com/SELinuxProject/selinux-notebook)
- Kernel source: `security/integrity/ima/`, `security/selinux/`, `security/apparmor/`
- Project fragments: `meta-iot-gateway/recipes-kernel/linux/files/fragments/`
  - `ima.cfg` — IMA measurement config
  - `selinux.cfg` — SELinux compiled-in + `CONFIG_LSM` string
  - `security-prod.cfg` — base KSPP hardening
