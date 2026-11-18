# Security Hardening

This document describes the security features and hardening measures implemented in the IoT Gateway OS.

For gateway-wide STRIDE scope, trust boundaries, and documentation classification policy,
see [Threat Model](THREAT_MODEL.md).

## Overview

The distribution implements defense-in-depth security across multiple layers:

- **Kernel Hardening**: KSPP-aligned security configuration
- **Compiler Hardening**: PIE, RELRO, FORTIFY_SOURCE
- **Runtime Hardening**: Secure sysctl settings, module blacklist
- **Audit Framework**: auditd with project audit rules
- **Firewall**: nftables enabled by default
- **Verified Boot and Root**: signed FIT boot (mandatory) and a dm-verity read-only root on both RAUC A/B slots
- **Mandatory Access Control**: SELinux enforcing (refpolicy-mcs + project module)

For FIT boot signing and verification chain setup, see the [FIT Boot and Signing Guide](FIT_BOOT_SIGNING.md).

SELinux is the active MAC and every image boots enforcing — see the
[SELinux Guide](SELINUX.md) for concepts and local wiring, and
[SELinux trials](SELINUX_ENFORCING.md) for on-board diagnostics. For IMA and TPM
notes, see [IMA and TPM Notes](LSM_IMA_EXPLORATION.md).

---

## Device Identity and Build Metadata Policy

### `/etc/machine-id` Policy

- `machine-id` is a host/runtime instance identifier used by systemd/DBus and OTA correlation.
- It is **not** a cryptographic device identity and must not be used as a trust anchor for attestation, licensing, or anti-cloning.
- Images must avoid shipping a fixed `machine-id`; each unit should end up with a unique value after provisioning/first boot and persist it across OTA updates.

### `/etc/buildinfo` Policy

- `DISTRO_*`, `IMAGE_*`, and `RAUC_BUNDLE_*` metadata are intentionally exposed for supportability and fleet operations.
- Production images should avoid unnecessary host build disclosures.
- Policy in this layer:
  - default (`dev`/`base`): includes `BUILD_SYS` for diagnostics.
  - `prod`: omits `BUILD_SYS` from `/etc/buildinfo` via `IOTGW_BUILDINFO_INCLUDE_BUILD_SYS = "0"`.

### Raspberry Pi EEPROM/OTP Policy

- Raspberry Pi EEPROM/serial/OTP values are useful for inventory and manufacturing correlation.
- Treat EEPROM/OTP identifiers as **non-secret hardware metadata**, not proof of device trustworthiness.
- Avoid irreversible OTP security fusing in early product stages unless manufacturing process, recovery strategy, and rollback policy are finalized.
- Preferred long-term trust model: TPM-backed key material + device certificate chain for identity and attestation.

---

## Kernel Hardening

The kernel follows Kernel Self Protection Project (KSPP) recommendations.

**Configuration:** `meta-iot-gateway/recipes-kernel/linux/files/fragments/security-prod.cfg`

**Key Categories:**
- **Memory Protection** — FORTIFY_SOURCE, INIT_ON_ALLOC/FREE, SLAB hardening, page poisoning
- **Stack Protection** — Stack canaries, VMAP_STACK, randomization
- **GCC Plugins** — STACKLEAK, STRUCTLEAK, LATENT_ENTROPY
- **Access Restrictions** — dmesg restrict, /dev/mem disabled; core dumps blocked at runtime (below)
- **ASLR** — Randomized kernel base; mmap entropy raised at runtime (below)
- **Attack Surface** — Debug interfaces disabled, staging drivers removed
- **Module Signing** — SHA256 signatures enforced
- **LSM** — SELinux mandatory access control (enforcing; see [SELINUX.md](SELINUX.md))
- **Audit** — Syscall auditing enabled

### Core dumps and mmap ASLR: runtime controls and their limits

`CONFIG_COREDUMP` and `CONFIG_ARCH_MMAP_RND_BITS` can only be changed with
`CONFIG_EXPERT=y`, which stays off because it exposes many unrelated knobs. The
kernel therefore keeps core-dump support and the default mmap entropy (18 bits),
and both controls live in userspace:

| Control | Where | Effect |
|---|---|---|
| `kernel.core_pattern = \|/bin/false` | systemd PID 1 at startup (`initialize_coredump()`), always | Core dumps are piped to `/bin/false` and discarded |
| `fs.suid_dumpable = 0` | `99-iotgw-hardening.conf` | No dumps of set-uid or credential-changed processes |
| `DefaultLimitCORE=0` | `system.conf.d/50-core-limits.conf` | RLIMIT_CORE 0 (soft and hard) for every systemd-started service and the sessions they spawn |
| `vm.mmap_rnd_bits = 33` | `99-iotgw-hardening.conf` | mmap base randomization at this kernel's maximum |

Limits, stated plainly:

- The kernel still produces core dumps when asked. Root (CAP_SYS_ADMIN) can
  rewrite `kernel.core_pattern` or `fs.suid_dumpable`, and root (CAP_SYS_RESOURCE)
  can raise RLIMIT_CORE, so these controls stop accidental and unprivileged dumps,
  not a privileged attacker.
- Before PID 1 runs, `core_pattern` is the kernel default (`core`). That covers
  the pre-init window (`init=/usr/sbin/iotgw-preinit`). PID 1 itself runs with
  RLIMIT_CORE unlimited, by systemd design.
- `vm.mmap_rnd_bits` applies only to processes started after `systemd-sysctl`.
  PID 1, pre-init and earlier units keep 18 bits. Root can lower the value. If a
  future kernel configuration lowers `ARCH_MMAP_RND_BITS_MAX` below 33, the write
  fails and `systemd-sysctl` logs it; the kernel default then stays in effect.
- `systemd-coredump` is not built, so `coredump.conf.d/iotgw.conf`
  (`Storage=none`) has no effect while it is not built. It is defence in depth, in case the
  coredump feature is ever enabled.

The `platform-smoke` target check (`scripts/run-target-checks.sh`, default
set) asserts `vm.mmap_rnd_bits` and `fs.suid_dumpable`; check the rest by hand
(`sysctl kernel.core_pattern`, `ulimit -c` in a login shell).

### CVE Response Workflow

When a kernel CVE affects a release between our pinned `SRCREV_machine`
and the next planned kernel bump, we carry the upstream stable backport
as a numbered patch in `meta-iot-gateway/recipes-kernel/linux/files/`.

See [Kernel CVE Patch — Field Guide](KERNEL_CVE_PATCH.md) for the
step-by-step workflow: identifying the right stable backport, annotating
for Yocto QA (`Upstream-Status:`, `CVE:`), wiring into `SRC_URI`, and
tracking the patch's sunset on the next `SRCREV` bump.

For image-wide scanning and userspace-package triage — generating the SBOM
and CVE report (`make sbom-cve`), reading it, and turning a scanner row into a
`CVE_STATUS` disposition — see [SBOM & CVE Scanning — Field Guide](SBOM_CVE.md).

---

## Compiler Hardening

Distribution-level compiler flags provide additional runtime protections.

**Configuration:** `meta-iot-gateway/conf/distro/include/iotgw-common.inc`

**Enabled Flags:**
- PIE (Position Independent Executables) — `-fPIE -pie`
- Full RELRO (GOT/PLT hardening) — `-Wl,-z,relro,-z,now`
- Stack canaries — `-fstack-protector-strong`
- Format string hardening — `-Wformat -Wformat-security`
- Buffer overflow detection — `-D_FORTIFY_SOURCE=2`

**Known exceptions in the prod image.** `scripts/security/elf-hardening-audit.sh`
over the prod rootfs flags two executables, both non-PIE (`EXEC`) with partial
RELRO. Neither comes from a flag being dropped by this layer:

| Executable | Package | Why it is not PIE | Disposition |
|---|---|---|---|
| `/usr/bin/vl805` | `rpi-eeprom` | Prebuilt 32-bit ARM binary; upstream ships no source, so it cannot be rebuilt with our flags | Updates the VL805 USB controller firmware of the Raspberry Pi 4. The Pi 5 has no VL805 (USB is on RP1), so it never runs on this product. Candidate for removal from the image |
| `/usr/bin/catatonit` | `catatonit` (meta-virtualization) | Statically linked by design: it is the minimal init podman injects into containers, so it must not depend on the container's libraries. A static non-PIE executable cannot have full RELRO | Accepted. Runs inside containers as their PID 1, with the container's privileges |

Any other executable the audit flags in prod is a regression and needs its own
justification here.

---

## Runtime Hardening

### System Configuration (sysctl)

**Configuration:** `meta-iot-gateway/recipes-support/iotgw-sysctl/files/90-iotgw.conf`

**Hardening overrides:** `meta-iot-gateway/recipes-security/iotgw-hardening/files/99-iotgw-hardening.conf`

**Network Security:**
- SYN flood protection (syncookies, retries, backlog)
- IP spoofing protection (rp_filter)
- ICMP/source route protection
- Martian packet logging

**Kernel Security:**
- dmesg restricted to root
- Kernel pointers hidden
- kexec load disabled at runtime (`kernel.kexec_load_disabled = 1`, one-way
  until reboot; `CONFIG_KEXEC`/`CONFIG_KEXEC_FILE` stay built in, recovery is
  A/B slot fallback through U-Boot)
- SysRq masked (`kernel.sysrq = 0`, and the kernel starts with an empty mask:
  `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0`); only the crash-debug lab profile
  re-enables it, from the signed command line (`sysrq_always_enabled=1`)
- perf events restricted
- ASLR enabled

**Process Hardening:**
- ptrace restricted to descendants (`kernel.yama.ptrace_scope = 1`)

### Module Blacklist

Unnecessary kernel modules are blacklisted to reduce attack surface.

**Configuration:** `meta-iot-gateway/recipes-security/iotgw-hardening/files/blacklist.conf`

### Other Hardening

- **File Permissions:** Default umask `027` (no world access)
- **Login Security:** Password aging, secure directory creation (`/etc/login.defs`).
  Password aging is enforced at login by `pam_unix`.
- **Logins through PAM:** console `login`, `sshd`, `sudo` and `newrole` use PAM.
  `pam_selinux` sets the session's SELinux domain and relabels the terminal;
  `pam_unix` checks passwords through `unix_chkpwd`, so login programs do not
  read `/etc/shadow` themselves. Stacks: `recipes-core/shadow/files/iotgw-pam-login`,
  `recipes-connectivity/openssh/files/iotgw-pam-sshd`.
- **SSH server:** `sshd.service` without a systemd namespace sandbox, so admin
  sessions see the real `/etc`, `/tmp` and `/run`; SELinux confines them by
  domain instead. Every tier is key-only: password and keyboard-interactive
  authentication and X11 forwarding are off (`99-iotgw.conf`), root logs in by
  key only (`PermitRootLogin prohibit-password`) and lands in `staff_t`. Prod
  repeats the key-only policy and disables TCP, Unix-socket, agent and tunnel
  forwarding (`10-iotgw-prod-auth.conf`); it ships no key and no password, so
  it has no login path at all (`docs/OPERATIONS.md` §5).
- **Admin elevation:** members of the `sudo` group get
  `ROLE=sysadm_r TYPE=sysadm_t` from `/etc/sudoers.d/10-iotgw-admin-selinux`;
  `newrole -r sysadm_r` re-authenticates through PAM. The serial console logs
  root straight into `sysadm_t`: physical access to the UART is administrator
  access.

---

## Audit Framework

### auditd Configuration

The `iotgw-audit` package provides project audit rules aligned to CIS-style baselines.
Rules are staged under `/usr/share/iotgw-audit/iotgw.rules` and deployed into
`/etc/audit/rules.d/iotgw.rules` during rootfs post-processing to avoid package
ownership conflicts with `auditd`.

**Persistence and retention:** the package also ships an explicit `auditd.conf`
(deployed the same way). Audit logs persist on `/data` — `/var/log/audit` is a
bind mount from `/data/log/audit` — and rotate at `max_log_file=16` MiB with
`num_logs=5` (~80 MiB nominal budget). Disk-pressure actions are deliberately
non-fatal for an unattended gateway (`disk_full_action=ROTATE`,
`disk_error_action=SYSLOG`, `admin_space_left_action=SYSLOG`), so a full or
failing `/data` cannot wedge auditing. The full persistent-state layout is in
[Persistent State Architecture](PERSISTENT_STATE.md).

**What's Audited:**
- File integrity (critical system files)
- User/group modifications
- Network configuration changes
- Sudoers and SSH server policy changes (file watches; no syscall rule for
  `setuid`/`execve` is loaded)
- Kernel module loading
- System calls (execve, mount, etc.)
- Failed authentication attempts

**Rules Location on target:**
``` 
/etc/audit/rules.d/iotgw.rules
```

**View Audit Logs:**
```bash
# Recent audit events
ausearch -ts recent

# Failed login attempts
ausearch -m USER_LOGIN -sv no

# Privilege escalation
ausearch -m USER_AUTH

# File access
ausearch -f /etc/passwd
```

---

## Firewall (nftables)

The distribution uses nftables (not iptables) for firewall configuration.

**Base Rules:**
Shipped by `iotgw-firewall` (`meta-iot-gateway/recipes-security/iotgw-firewall`),
which installs its `nftables.conf` and checks the rules at build time. Input
is default-deny with family-qualified service rules. Forwarding is
default-deny too: the kernel forwards (`ip_forward` is on for the Thread
border router), so the chain names the only interface pair that may be
forwarded — Thread `wpan0` to and from the OTBR infrastructure interface,
spliced in only when the OTBR feature is built — and nothing else. Rootless
containers (pasta) terminate in host sockets and need no forwarding entry.

**Loading:** `iotgw-nftables.service` loads the ruleset before
`network-pre.target` and before `sshd.service`, so no interface is configured
and no listener is up under the kernel's default accept policy. It validates
the file first (`nft -c`), and if loading fails anyway its `ExecStopPost=`
helper installs a minimal fail-closed ruleset (loopback, established flows,
ICMP, SSH on IPv4, no forwarding) instead of leaving the box open.

**Configuration:**
```
/etc/nftables.conf
```

**Basic Management:**
```bash
# View current ruleset
nft list ruleset

# Reload rules
systemctl reload nftables
```

Enablement and rules are image configuration: a runtime change under `/etc`
is discarded at the next reboot.

---

## Security Validation

### Kernel Hardening Check

Validate kernel configuration against KSPP recommendations using the `kernel-hardening-checker` tool. The development image includes the tool through the dev package group; other variants can add it from meta-oe if needed.

**On the running device:**
```bash
kernel-hardening-checker -c /proc/config.gz -m verbose
```

Over SSH from the host:
```bash
ssh root@<device> 'zcat /proc/config.gz | kernel-hardening-checker -c - -m verbose'
```

Run the check against a running device using the kernel's own `/proc/config.gz`.

**What It Checks:**
- Memory protection features
- Stack protection mechanisms
- Access restrictions
- Attack surface reduction
- GCC security plugins
- Module signing
- ASLR configuration

**Report Format:**
- ✅ OK — Security feature properly configured
- ⚠️ FAIL — Recommended feature missing
- ❌ ERROR — Configuration issue

### System Audit (Lynis)

Lynis performs comprehensive security audits of the running system.

**Quick Audit:**
```bash
lynis audit system --quick
```

**Full Audit:**
```bash
lynis audit system
```

**Output:**
- Log: `/var/log/lynis.log`
- Report: `/var/log/lynis-report.dat`

**What It Checks:**
- Boot and services
- Kernel configuration
- File permissions
- User accounts and authentication
- File integrity
- Networking
- Software packages
- Logging and monitoring

**Establishing Baseline:**
```bash
# First boot audit (full log + normalized summary)
lynis audit system --quick --no-colors > /data/lynis-baseline.log
grep -E 'hardening_index=|^warning\[\]=|^suggestion\[\]=' /var/log/lynis-report.dat \
  > /data/lynis-baseline.summary

# Compare over time
lynis audit system --quick --no-colors > /tmp/lynis-current.log
grep -E 'hardening_index=|^warning\[\]=|^suggestion\[\]=' /var/log/lynis-report.dat \
  > /tmp/lynis-current.summary
diff -u /data/lynis-baseline.summary /tmp/lynis-current.summary
```

Lynis has no test for listener address family or bind scope, which is why the
listening-socket check below exists as a separate, independent control — it is
not a Lynis finding this product tunes toward.

### Listening Socket Check

Asserts that only the intended sockets are listening, on the intended address
families, and that the firewall's rules are family-qualified.

```bash
scripts/run-target-checks.sh <device-ip> exposure
```

Two independent layers, because they catch different things:

| Layer | Runs | Catches |
|---|---|---|
| `iotgw-listen-guard.bbclass` | every image build, no board needed | a socket unit binding an unintended address; covers variants that have never been flashed. The image ships no network socket unit, so it guards against one appearing |
| `scripts/security/exposure-target.sh` | on a running target | the resulting system, including daemons that bind their own sockets and the live firewall ruleset |
| `scripts/security/exposure-probe-host.sh` | from a second host | actual reachability — a device cannot prove its own |

**The SSH listen scope.** `sshd` runs as one daemon (`sshd.service`,
`sshd -D`) and binds its own listener, so `AddressFamily` and `ListenAddress`
in its configuration decide the scope. Unset, sshd binds **dual-stack**
(`*:22`); on a device holding a global IPv6 address that is an un-NATed,
publicly routable management port. `sshd_config.d/05-iotgw-listen.conf`, shipped
inside `openssh-sshd`, pins it to `AddressFamily inet` and `ListenAddress
0.0.0.0`. sshd keeps the first value it reads for a keyword, so a later drop-in
cannot widen it. No build-time guard reads this file: the listen guard covers
socket units only, and `exposure-target.sh` asserts the scope on the target
with `sshd -T` and `ss`.

The same class applies to the firewall: in a `table inet`, a rule naming a port
with no family match admits it on IPv4 **and** IPv6. Every service rule in
`nftables.conf` carries an explicit `meta nfproto` match, enforced at build time
by `iotgw-firewall.bb` and at runtime by `exposure-target.sh`.

---

## TPM 2.0 (Infineon SLB9672)

For the TPM roadmap, see [TPM Requirements](TPM_REQUIREMENTS.md).

When `IOTGW_ENABLE_TPM_SLB9672=1`, the following TPM security components are included:

### Device Policy (`iotgw-tpm-policy`)
- Dedicated `iotgwtpm` system user/group for least-privilege TPM access
- udev rules enforce ownership on TPM device nodes:
  - `/dev/tpmrm0` (resource manager): `root:iotgwtpm 0660` — group-accessible for applications
  - `/dev/tpm0` (raw device): `root:root 0600` — root-only, prevents direct hardware access

### Userspace Tools
- **`tpm-ops`** — Rust CLI for TPM operations (info, TRNG, PCR reads, hashing, signing)
- **`tpm2-tools`** — Low-level TPM2 CLI (dev image only)
- Default TCTI policy is pinned to `device:/dev/tpmrm0` to avoid simulator/fallback ambiguity.

### Optional TPM Crypto Providers

Enable extra userspace integrations for PKCS#11/OpenSSL consumers:

- `tpm2-pkcs11`
- `tpm2-openssl`
- `tpm2-tss-engine`

Build-time gate: `IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS` follows the TPM switch
`IOTGW_ENABLE_TPM`; set it on its own only to diverge from the switch.

Notes:
- Gate is additive and only effective when `IOTGW_ENABLE_TPM_SLB9672=1`.
- On OpenSSL 3 builds, provider-based integration is preferred; `openssl engine`
  output may stay minimal even when TPM crypto provider packages are installed.

### Kernel Support
- Fragment: `meta-iot-gateway/recipes-kernel/linux/files/fragments/tpm-slb9672.cfg`
- TIS-SPI stack over RP1 DesignWare SPI controller
- TPM TRNG feeds kernel entropy pool (`CONFIG_HW_RANDOM_TPM=y`)
- `/dev/spidev` intentionally disabled on TPM chip-select to prevent conflicts

### Build-Time Enablement
Include `kas/tpm.yml` in `kas/local.yml`: it composes the TPM layers and sets
the TPM switch `IOTGW_ENABLE_TPM = "1"`, which enables the hardware profile,
crypto providers, OTA TPM mTLS and PKCS#11 RAUC streaming together. To keep the
layers but switch the TPM off, set `IOTGW_ENABLE_TPM = "0"` under the same
`tpm_spi` block name in `kas/local.yml`.

---

## Security Checklist

### Production Deployment

Before deploying to production:

- [ ] Dev/desktop only: set `IOTGW_ROOT_PASSWORD_HASH` and `IOTGW_DEVEL_PASSWORD_HASH` in `kas/local.yml` (layer default `*` = no password); a password changed on the device is lost at reboot (`/etc` is reset). Prod: root is `*` by recipe and the build enforces it; no account has a password
- [ ] Generate unique RAUC signing keys (per deployment/fleet)
- [ ] Review and customize firewall rules
- [ ] Confirm `igw_security_prod` is still in `IOTGW_KERNEL_FEATURES` (default on) if you override that variable
- [ ] Run `kernel-hardening-checker -c /proc/config.gz` on the deployed device and review the report
- [ ] Regenerate the Lynis baseline and review the diff against the previous release's baseline
- [ ] Audit binary hardening (PIE, RELRO, NX) over the image's extracted rootfs (`scripts/security/elf-hardening-audit.sh`) and justify every executable it flags
- [ ] Verify only expected TCP/UDP listeners are present (`run-target-checks.sh <ip> exposure`)
- [ ] Confirm reachability from a second host on every zone the device attaches to, over **both** IPv4 and IPv6 (`exposure-probe-host.sh`) — a device cannot prove its own reachability
- [ ] Disable unused network services
- [ ] Configure audit log forwarding (if applicable)
- [ ] Prod has no administrator: its only login is the OTA operator `iotgw-ops` (key from `IOTGW_PROD_OPS_AUTH_KEYS_FILE`, `staff_t`, bundle staging and `rauc` only). Confirm the OTA channel is provisioned on the card (`/boot/iotgw/ota/` device certificate, `updater.conf`); OTA (automatic or by the operator) and reflash are the only administration paths (`docs/OPERATIONS.md` §5)
- [ ] Build prod through `make prod` / `make bundle-prod-full-fit` so `kas/uboot-prod-hardening.yml` is composed; the prod hygiene gate fails any other composition (dev kernel fragments, missing `appliance_lockdown`)
- [ ] Review sysctl settings for your use case
- [ ] Test OTA update rollback mechanism

### Ongoing Maintenance

- [ ] Regularly update base OS and packages
- [ ] Review audit logs for anomalies
- [ ] Re-run Lynis audits quarterly
- [ ] Monitor CVE databases for kernel/package vulnerabilities
- [ ] Rotate RAUC signing keys annually
- [ ] Test disaster recovery procedures

---

## Additional Resources

- [Kernel Self Protection Project](https://kspp.github.io/)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks)
- [NIST Security Guidelines](https://www.nist.gov/cyberframework)
- [OWASP Embedded Security](https://owasp.org/www-project-embedded-application-security/)
