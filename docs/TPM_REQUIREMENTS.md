# TPM 2.0 Requirements

This document describes the requirements and work plan for Linux-side TPM enablement and
measured-boot design on the Raspberry Pi 5 (Infineon SLB9672). U-Boot TPM integration is
parked pending upstream RP1/PCIe/SPI support.


## Overview

This project has TPM building blocks in place. This document defines what problem we are
solving, what is already working, what we want to achieve next, and what is intentionally
out of scope.

## Current State (What We Have)
- Hardware target: Infineon SLB9672 class TPM2 over SPI on RPi5.
- Kernel/device enablement exists behind feature gate `IOTGW_ENABLE_TPM_SLB9672=1`.
- Userspace includes TPM policy and tooling (`tpm-ops`; `tpm2-tools` in dev profile).
- RAUC/FIT/OTA flow currently works without U-Boot TPM integration.
- U-Boot TPM integration attempt was parked due to upstream and stability blockers.

## Problem Statement
We need trustworthy TPM-backed security capabilities on the gateway without breaking stable OTA/boot flows.

Specifically:
1. TPM must be reliably usable from Linux on production images.
2. We need a clear measured-boot design (what is measured, where, and why).
3. We need operable diagnostics and post-update verification so TPM regressions are visible.

## Goals
1. Reliable Linux TPM runtime
- Deterministic TPM access (`/dev/tpmrm0` preferred).
- Consistent user/group/device-node policy.
- Repeatable health checks on boot and post-update.

2. Measured-boot design baseline
- Define PCR allocation policy.
- Define event-log format/location and retrieval.
- Define expected PCR baseline policy per image/slot/kernel version.

3. Operational readiness
- Add minimally invasive TPM checks to update validation workflow.
- Document troubleshooting and failure handling.

## Non-Goals (For Now)
- No U-Boot TPM SPI bring-up work.
- No OTP fuse burn or secure-boot enforcement rollout.
- No full remote attestation backend implementation yet.
- No migration to a different OTA framework for TPM reasons.

## Constraints and Assumptions
- Current stable boot/update path must remain unchanged.
- Any TPM addition must be non-disruptive to RAUC install and slot switching.
- Build profile split remains:
  - `dev`: debugging tools allowed (`tpm2-tools`).
  - `prod`: least-privilege runtime surface.

## Target Outcomes
When this track is complete, we should be able to say:
1. TPM is present and healthy on every production boot.
2. Measured-boot policy is documented and testable.
3. Post-OTA checks confirm TPM functionality and capture evidence.
4. On-call/operator docs exist for common TPM failure modes.

## Work Plan

### Phase 1: Runtime Baseline (Linux TPM)
Deliverables:
- TCTI default policy documented and enforced (`device:/dev/tpmrm0`).
- Boot-time non-blocking TPM health unit/service.
- Standard output artifact for health checks in `/data/ota/` or equivalent.

Acceptance:
- `tpm2_getcap properties-fixed` works after cold boot and reboot.
- PCR read command succeeds consistently.
- No regressions in boot time or OTA success path.

### Phase 2: Measured-Boot Design
Deliverables:
- PCR ownership matrix (bootloader/FIT/kernel/initramfs/userspace).
- Event model: what gets extended, by which component, and when.
- Evidence retrieval format and location.

Acceptance:
- Reviewable design doc with explicit PCR mapping.
- Reproducible sample measurements on target.
- Clear distinction between "implemented now" and "future hardening".

### Phase 3: OTA Integration and Operations
Deliverables:
- Post-install/post-boot TPM verification steps integrated into ops workflow.
- Failure policy (warn/fail-open/fail-closed) defined per environment.
- Troubleshooting section with known-good command set.

Acceptance:
- OTA to inactive slot + reboot retains TPM functionality.
- Validation results are captured and auditable.

## Minimum Command Set (Learning + Ops)
Use these as baseline checks on target:
- `ls -l /dev/tpm*`
- `tpm2_getcap properties-fixed`
- `tpm2_pcrread sha256:0,1,2,3,4,5,6,7`
- `tpm2_getrandom 16`

## Risks
- Kernel/device-tree drift can silently break TPM probing.
- Userland tool defaults (TCTI fallback) can hide real device-path issues.
- Measured-boot policy can become inconsistent without strict PCR ownership rules.

## Open Questions
1. Which PCRs are mandatory for policy decisions vs informational only?
2. Where should event logs live long-term for fleet attestation?
3. What is the production policy if TPM is unavailable at boot (degraded mode vs hard fail)?

## Decision Log
- 2026-04-01: U-Boot TPM integration remains parked; Linux-side TPM is active path.
- 2026-04-01: Focus shifts to requirements + measured-boot design before new implementation.
