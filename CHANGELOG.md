# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-03-04

### Added
- Mainline kernel/FIT flow for Raspberry Pi 5 with signed FIT boot path and verification.
- RAUC OTA stack with A/B slots, HTTPS streaming support, bundle hooks, updater/cert provisioning, and adaptive slot alignment guardrails.
- OTBR integration with hardened services, firewall gating, and web UI integration.
- Edge monitoring foundation via `edge-healthd` recipe integration and packaging alignment.
- RAUC wrapper hardening under systemd-run with explicit namespace/write-path assumptions and audit markers.

### Changed
- RAUC update behavior hardened across preflight, TLS profile selection, and D-Bus observability paths.
- Machine identity handling updated for immutable rootfs: persistent `/data/machine-id` bound into `/etc/machine-id` with runtime fallbacks.
- RAUC config recipe resolution hardened to avoid filename/FILESPATH collisions.
- Build workflow expanded with FIT-focused bundle targets (`bundle-dev-full-fit`, fast base FIT bundle target).

### Fixed
- First-boot bootargs regression and adaptive slot geometry misalignment handling.
- OTA certificate CA source-of-truth and chain validation behavior.
- Post-update service/image integration issues around U-Boot env follow-up paths.
- Bootfiles/FIT payload consistency issues affecting runtime boot reliability.
- SSH hardening interaction that blocked expected sudo behavior under per-connection service mode.

### Security
- Broader service hardening and sandboxing coverage (systemd hardening drop-ins, namespace controls).
- NVMe module loading restrictions and platform hardening updates.
- OTA/update-path reliability hardening to reduce unsafe manual recovery scenarios.

### Documentation
- Expanded runbooks for build, security, partitions, RAUC OTA, FIT signing, and OTBR operation.
- Added adaptive OTA benchmark and troubleshooting guidance for field validation.

[Unreleased]: https://github.com/umair-as/rpi5-iot-gateway/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/umair-as/rpi5-iot-gateway/releases/tag/v0.1.0
