# Threat Model (Gateway-Wide, STRIDE)

This document is the public, repository-safe threat model for the IoT Gateway OS.
It captures architecture-level threats and controls without disclosing operational secrets.

Keep private investigations, incident notes, and sensitive assumptions in internal-only notes outside version control.

## Scope

In scope:
- Secure boot chain (RPI firmware -> U-Boot -> FIT -> kernel/initramfs)
- OTA update path (RAUC A/B, bundle verification, slot switching)
- Runtime configuration persistence (`/etc` overlay reconciliation)
- Provisioning path (`/boot` inputs -> on-device config/cred stores)
- Core services (networking, OTA, observability, container runtime, TPM helpers)
- Local/remote management interfaces (SSH, D-Bus mediated services)

Out of scope:
- Fleet backend internals not in this repository
- Third-party cloud account controls

## Security Objectives

1. Prevent unauthorized code execution in boot and update paths.
2. Keep credentials out of immutable images and minimize runtime exposure.
3. Preserve integrity of configuration across OTA while allowing controlled local changes.
4. Maintain least privilege for long-running services.
5. Ensure auditable security events and recoverable failure behavior.

## Trust Boundaries

1. Build host/CI -> signed artifacts
2. Signed artifact store -> target device OTA installer
3. Read-only rootfs slots -> writable `/data` and `/etc` overlay upper
4. Boot partition (`/boot`) -> privileged provisioning services
5. Local root/admin shell -> all runtime secret and control planes
6. Network ingress (MQTT/SSH/management) -> internal services

## Key Assets

- Boot keys, RAUC trust anchors, bundle signatures
- Device identity and TPM-backed material
- OTA state, rollback metadata, slot status
- Service credentials and auth policy stores
- Network configuration and access-control policy
- Security logs and audit trails

## STRIDE Summary

### Spoofing
- Risks: rogue bundle source, forged provisioning inputs, impersonated device/service.
- Baseline controls: signed FIT/RAUC artifacts, TLS/cert trust roots, service account isolation.
- Planned controls: stronger device identity binding and signed bootstrap payloads.

### Tampering
- Risks: modification of overlay-managed configs, credential stores, OTA metadata.
- Baseline controls: managed-path reconciliation, read-only rootfs, hardened service permissions.
- Planned controls: additional integrity checks and post-OTA verification gates.

### Repudiation
- Risks: inability to prove who changed security-relevant configuration.
- Baseline controls: journald/auditd coverage, build/version metadata exposure.
- Planned controls: structured security event catalog and retention policy by profile.

### Information Disclosure
- Risks: plaintext credentials in env/argv/files, debug surfaces leaking sensitive state.
- Baseline controls: credential store migration, reduced env secret usage, hardened file modes.
- Planned controls: TPM-sealed secret strategy and reduced runtime secret materialization.

### Denial of Service
- Risks: failed slot transitions, bad config persistence, service hardening regressions.
- Baseline controls: A/B rollback semantics, conservative provisioning behavior, restart policies.
- Planned controls: health gates for critical services in OTA validation.

### Elevation of Privilege
- Risks: overly broad service permissions/capabilities, weak syscall boundaries.
- Baseline controls: systemd sandboxing, non-root services, read-only system partitions.
- Planned controls: per-service hardening matrix with compatibility tests.

## Service Security Baseline

Every new or modified service should be reviewed for:
- `User=`/`Group=` non-root operation
- `NoNewPrivileges=yes`
- Read-only filesystem posture (`ProtectSystem`, scoped `ReadWritePaths`)
- Capability minimization (`CapabilityBoundingSet=`, `AmbientCapabilities=`)
- Syscall and namespace restrictions when compatible
- Secret handling path (no secrets in image defaults; avoid argv leaks)

## Public vs Private Documentation Policy

Use `docs/` for:
- Architecture and control objectives
- Threat categories, boundaries, and mitigations
- Non-sensitive operational guidance

Use private/internal notes (not committed) for:
- Incident details, exploit hypotheses, and live debugging artifacts
- Temporary risk acceptance notes
- Sensitive assumptions not ready for publication

Promotion rule:
- Start in private/internal notes when uncertain.
- Promote to `docs/` after sanitization and validation.
- Keep sensitive values, hostnames, private endpoints, and exploit specifics out of `docs/`.

## Current Focus Areas

1. Credential lifecycle hardening across all services.
2. OTA security verification gates (pre/post install).
3. TPM-backed production secret model.
4. Formal service hardening checklist enforcement in CI.

## Related Documents

- `docs/SECURITY.md`
- `docs/RAUC_UPDATE.md`
- `docs/FIT_SIGNING.md`
- `docs/KERNEL.md`
- `docs/NETWORKING.md`
