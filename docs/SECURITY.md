# Security Hardening

This document describes the security features and hardening measures implemented in the IoT Gateway OS.

## Overview

The distribution implements defense-in-depth security across multiple layers:

- **Kernel Hardening**: KSPP-aligned security configuration
- **Compiler Hardening**: PIE, RELRO, FORTIFY_SOURCE
- **Runtime Hardening**: Secure sysctl settings, module blacklist
- **Audit Framework**: auditd with comprehensive rules
- **Firewall**: nftables enabled by default
- **Read-only Root**: RAUC A/B slots mounted read-only

For FIT boot signing and verification chain setup, see [FIT Setup and Signing Guide](FIT_SIGNING.md).

---

## Kernel Hardening

The kernel follows Kernel Self Protection Project (KSPP) recommendations.

**Configuration:** `meta-iot-gateway/recipes-kernel/linux/files/fragments/security-prod.cfg`

**Key Categories:**
- **Memory Protection** — FORTIFY_SOURCE, INIT_ON_ALLOC/FREE, SLAB hardening, page poisoning
- **Stack Protection** — Stack canaries, VMAP_STACK, randomization
- **GCC Plugins** — STACKLEAK, STRUCTLEAK, LATENT_ENTROPY
- **Access Restrictions** — dmesg restrict, /dev/mem disabled, no core dumps
- **ASLR** — Randomized kernel base, increased entropy
- **Attack Surface** — Debug interfaces disabled, staging drivers removed
- **Module Signing** — SHA256 signatures enforced
- **LSM** — AppArmor mandatory access control
- **Audit** — Syscall auditing enabled

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

---

## Runtime Hardening

### System Configuration (sysctl)

**Configuration:** `meta-iot-gateway/recipes-support/iotgw-hardening/files/99-iotgw-sysctl.conf`

**Network Security:**
- SYN flood protection (syncookies, retries, backlog)
- IP spoofing protection (rp_filter)
- ICMP/source route protection
- Martian packet logging

**Kernel Security:**
- dmesg restricted to root
- Kernel pointers hidden
- kexec disabled
- perf events restricted
- ASLR enabled

**Process Hardening:**
- ptrace restricted to parent processes

### Module Blacklist

Unnecessary kernel modules are blacklisted to reduce attack surface.

**Configuration:** `meta-iot-gateway/recipes-security/iotgw-hardening/files/blacklist.conf`

### Other Hardening

- **File Permissions:** Default umask `027` (no world access)
- **Login Security:** Password aging, secure directory creation (`/etc/login.defs`)

---

## Audit Framework

### auditd Configuration

The `iotgw-audit` package provides comprehensive audit rules based on CIS benchmarks.

**What's Audited:**
- File integrity (critical system files)
- User/group modifications
- Network configuration changes
- Privilege escalation (sudo, su)
- Kernel module loading
- System calls (execve, mount, etc.)
- Failed authentication attempts

**Rules Location:**
```
/etc/audit/rules.d/iotgw-audit.rules
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
Installed by the `nftables` package with IoT gateway defaults.

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

# Enable at boot
systemctl enable nftables
```

---

## Security Validation

### Kernel Hardening Check

Validate kernel configuration against KSPP recommendations using the `kernel-hardening-checker` tool.

**During Build (host-side check using build artifacts):**
```bash
scripts/kernel-hardening-check-build.sh
```

Output: `build/reports/kernel-hardening-YYYYMMDD-HHMMSS.txt`

**On Running Device (over SSH):**
```bash
scripts/kernel-hardening-check-target.sh root@192.168.1.100
```

Or manually on device:
```bash
kernel-hardening-checker -c /proc/config.gz
```

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
# First boot audit
lynis audit system > /data/lynis-baseline.txt

# Compare over time
diff /data/lynis-baseline.txt <(lynis audit system)
```

---

## Security Checklist

### Production Deployment

Before deploying to production:

- [ ] Change default passwords (`root`, `devel`)
- [ ] Generate unique RAUC signing keys (per deployment/fleet)
- [ ] Review and customize firewall rules
- [ ] Enable kernel security features (`igw_security_prod`)
- [ ] Run `scripts/kernel-hardening-check-build.sh` and review the report
- [ ] Run Lynis audit and address findings
- [ ] Disable unused network services
- [ ] Configure audit log forwarding (if applicable)
- [ ] Set up SSH key-based authentication
- [ ] Disable root password login via SSH
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
