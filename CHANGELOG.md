# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-04-08

### Added
- U-Boot bootstage userspace collector service (`iotgw-bootstage`) with structured logging and environment export.
- Stable RAUC slot udev links (`/dev/disk/by-rauc-slot/*`) for early boot partition resolution.

### Changed
- Raspberry Pi 5 U-Boot boot path optimized for appliance flow with script-first behavior.
- U-Boot boot interaction refined to a 2s keyed stop string (`igw`) with image-variant bootdelay policy.
- U-Boot diagnostics expanded with stage markers and bootstage reporting path for fleet timing analysis.
- Startup critical path improved by removing `udev-settle` dependency from `rauc-grow-data-partition`.
- Network boot wait behavior hardened by masking `NetworkManager-wait-online` at rootfs build time.
- Systemd preset installation path corrected to `${libdir}/systemd/system-preset` for deterministic application during image build.

### Fixed
- Resolved RPi5 U-Boot init/probe regressions encountered during EFI/video/DM path tuning.
- Audit rule deployment moved away from fragile `pkg_postinst` flow to deterministic rootfs deployment.
- AArch64 audit rule compatibility fixed (invalid syscall usage removed), with reliable `augenrules` load.
- File/dir audit monitoring switched to watch-form rules for stable boot-time rule activation.
- `devel` account password aging policy adjusted to avoid forced expiry lockouts on first login after OTA.
- Overlay reconcile policy updated to enforce `/etc/login.defs` consistency across slot switches.

### Security
- Login policy hardening moved to `shadow` package build-time patching (`/etc/login.defs`) for OTA-consistent behavior.
- Audit policy profile clarified with image-profile lock mode handling (`-e 1` dev/base, stricter prod policy support).

### Documentation
- Security documentation updated for current audit rules path and Lynis baseline workflow.
- Partition documentation updated for current grow-data detection/stamp behavior.

## [0.2.0] - 2026-04-01

### Added
- TPM 2.0 (Infineon SLB9672) integration with build-time gating across kernel/device-tree/userspace packaging.
- FIT Strategy A recovery-kernel flow for signed multi-config boot updates.
- Rootfs-only dev bundle target for faster OTA iteration (`bundle-dev` path).

### Changed
- FIT custom ITS flow advanced to Phase B (dual-kernel + dual-config policy with `conf-primary`/`conf-recovery`).
- OTA cert provisioning and RAUC install wrapper flow reconciled for HTTPS-driven installs.
- WIC/OTA layout moved to 128G default with 16G A/B rootfs slots and hardened streaming preflight behavior.

### Fixed
- Raspberry Pi 5 RTC support backported behind build-time gate (`IOTGW_ENABLE_RPI_RTC`).
- U-Boot boot path adjusted to skip unused EFI boot method probes for this product flow.

### Documentation
- Security and FIT signing documentation refreshed for current runtime policy and operator workflow.
- OTA follow-up notes and repository references aligned with merged implementation state.

## [0.1.0] - 2026-03-04

### Added
- Mainline Linux `6.18` integration and FIT bundle flow for Raspberry Pi 5.
- Signed FIT boot path support with runtime verification plumbing and key injection flow.
- RAUC bundle-hook bootfiles update path with U-Boot environment tracking.
- RAUC HTTPS streaming support in system config, including TLS paths and operator runbook coverage.
- OTA updater service/timer and OTA certificate provisioning pipeline with dev-CA support.
- Dedicated `uboot-env` partition support and RAUC slot/layout handling updates.
- Adaptive OTA slot-alignment build validation gate for rootfs slots.
- Deterministic RAUC streaming preflight stages with TLS profile selection (`system`/`data`).
- RAUC D-Bus integration across updater, manual wrapper, and banner observability.
- Persistent machine-id flow for immutable rootfs (`/data/machine-id` -> `/etc/machine-id`) with consumer fallbacks.
- OTBR host integration improvements, including hardened services, system user setup, telemetry flags, and `iotgw-otbrctl`.
- OTBR web UI integration and default/network policy gating by `IOTGW_ENABLE_OTBR`.
- Edge monitoring integration (`edge-healthd`) with packagegroup gating and refactor to `.inc + versioned .bb`.
- Platform support additions for container-host tuning and mosquitto security integration.

### Changed
- Build workflow expanded with FIT-focused bundle targets (`bundle-dev-full-fit`, `bundle-base-full-fit-fast`).
- OTA cert trust source aligned to a single CA source-of-truth with runtime chain validation.
- RAUC config recipe selection hardened to avoid filename and `FILESPATH` collisions.
- `iotgw-rauc-install` execution model hardened under `systemd-run` with explicit transient unit controls.
- Wrapper audit behavior improved with dispatch profile and writable-path assumption logs.
- Image defaults updated to mask legacy `vconsole` and legacy `rauc-mark-good` behavior in favor of updated flow.
- Packagegroups and image composition updated for OTA dependencies and developer tooling.

### Fixed
- First-boot bootargs regression that could carry stale static root arguments.
- Post-`uboot-env` follow-up service/image integration issues.
- FIT boot reliability issues around stale bootfiles payload and signed image/runtime DTB consistency.
- U-Boot FIT hash verification compatibility (`sha256`) path.
- OTA overlay reconciliation reliability in slot hooks (`pre-install`/`post-install`) and migration behavior.
- OTBR web UI regressions (missing frontend assets, tested defaults, nft init behavior).
- SSH per-connection hardening side effect that blocked expected sudo usage.
- Build/QA issues in OTBR path (including buildpath QA and telemetry enablement).

### Security
- Broader service hardening and sandboxing coverage (systemd hardening drop-ins, namespace controls).
- NVMe module loading restrictions and related hardening updates.
- RAUC/manual install-path hardening for namespace-constrained contexts.
- OTA/update-path reliability hardening to reduce unsafe manual recovery scenarios.
- Firewall rule gating improvements for OTBR-enabled deployments.

### Documentation
- Expanded runbooks for build, security, partitions, RAUC OTA, FIT signing, and OTBR operation.
- Added adaptive OTA benchmark and troubleshooting guidance for field validation.
- Added HTTPS streaming OTA notes and refreshed operational docs for build/partition/security flows.

[Unreleased]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/umair-as/rpi5-iot-gateway/releases/tag/v0.1.0
