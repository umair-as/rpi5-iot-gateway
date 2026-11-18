# IMA and TPM Notes

Notes on the Integrity Measurement Architecture (IMA) and its interaction with the
SPI-attached TPM on the Raspberry Pi 5: concepts, the kernel configuration, the PCR10
limitation, and target commands. IMA is opt-in (`IOTGW_ENABLE_IMA`). For the MAC (SELinux)
see [SELINUX.md](SELINUX.md); for TPM requirements see
[TPM_REQUIREMENTS.md](TPM_REQUIREMENTS.md).

---

## Table of Contents

1. [IMA — Integrity Measurement Architecture](#1-ima--integrity-measurement-architecture)
2. [TPM Interaction with IMA](#2-tpm-interaction-with-ima)
3. [Target Command Reference](#3-target-command-reference)
4. [Known Issues / Open Items](#4-known-issues--open-items)

---

## 1. IMA — Integrity Measurement Architecture

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
- PCR10 accumulates the measurement log hash (blocked on RPi5 by SPI ordering — see section 2)
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

**Selecting the policy.** The kernel command line is fixed at build time and
signed into the slot FIT, so `ima_policy=tcb` goes in
`IOTGW_VERITY_KERNEL_ARGS` (build time); it cannot be set from the U-Boot
environment.

With `ima_policy=tcb` active:

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

### Checking that IMA is logging

```bash
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
```

A non-zero count means IMA is logging measured files.

### IMA kernel config (`ima.cfg`, `igw_ima`, gated by `IOTGW_ENABLE_IMA`)

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

## 2. TPM Interaction with IMA

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

Result: the IMA log is populated, but PCR10 is all zeros. Remote attestation
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

1. **Early-userspace extend** — an early-boot step reads the IMA log and extends a PCR
   once the TPM is reachable. There is no initramfs; this would run from pre-init or an
   early unit, with tpm2-tools available there.
2. **U-Boot TPM extend** — U-Boot extends PCRs for FIT blob hashes. RP1 SPI problem exists
   at U-Boot stage too (parked).
3. **OS-managed PCR** — Seal keys to a PCR the OS controls (e.g. PCR7), rather than relying
   on firmware measured boot.
4. **Software-only audit** — Use IMA log for forensics without TPM sealing. Tamper-evident
   (you can detect tampering post-incident) but not tamper-proof at runtime.

---

## 3. Target Command Reference

All commands run as root on the target.

### IMA measurement log

```bash
# IMA sysfs directory
ls /sys/kernel/security/ima/
# ascii_runtime_measurements  binary_runtime_measurements  policy  violations

# How many files measured since boot
wc -l /sys/kernel/security/ima/ascii_runtime_measurements

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
# Current cmdline (shows ima_policy=tcb if the build set it)
cat /proc/cmdline
```

### Kernel config spot-checks

```bash
# IMA compiled in?
zcat /proc/config.gz | grep 'CONFIG_IMA[^_]'
# CONFIG_IMA=y
```

---

## 4. Known Issues / Open Items

### IMA TPM PCR10 always zero (hardware constraint)

SPI-attached SLB9672 comes up after IMA kernel subsystem initialises. TPM-bypass active.
PCR10 remains zero. IMA log is populated and readable; TPM sealing is not.
No fix in the current boot topology.

### `evmctl ima_measurement` fails (IBM TSS missing)

`evmctl` requires `tsspcrread` from IBM TSS. Image uses TSS2 (`tpm2-tools` / `tpm-ops`).
Use `tpm2_pcrread sha256:10` as the equivalent PCR read command.

---

## References

- [IMA kernel docs](https://www.kernel.org/doc/html/latest/security/IMA-templates.html)
- [IMA Wiki](https://sourceforge.net/p/linux-ima/wiki/Home/)
- Kernel source: `security/integrity/ima/`
- Project fragment: `meta-iot-gateway/recipes-kernel/linux/files/fragments/ima.cfg`
