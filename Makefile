.PHONY: help base dev prod desktop \
        bundle-dev bundle-dev-full bundle-dev-full-fit sign-bootfiles-fit-yk sign-bootfiles-fit-softhsm bundle-dev-full-fit-resign bundle-base-full-fit-fast bundle-prod-full bundle-prod-full-fit bundle-prod-full-fit-resign bundle-desktop-full bundle-desktop \
        tools-venv test-sign-fit test-sign-fit-softhsm \
        layers parse clean-lock

KAS ?= kas

# === Shared-layer build mechanism (git-alternates; see kas/local.yml.example) ===
# KAS_REPO_REF_DIR points at a shared bare-repo cache scoped per Yocto release
# (layers-wrynose). kas clones each layer into .kas/ (gitignored) using those
# repos as git alternates — near-instant setup, zero extra disk, and the SHA
# pins in rpi5.yml/kas/*.yml are still enforced. A mirror missing from the
# ref-dir is auto-created on first use; an absent ref-dir falls back to full
# clones (no error). KAS_WORK_DIR keeps upstream layer clones out of the repo
# root; KAS_BUILD_DIR keeps the bitbake build dir at the conventional ./build.
KAS_REPO_REF_DIR ?= /mnt/yocto-nvme/layers-wrynose
KAS_WORK_DIR     ?= $(CURDIR)/.kas
KAS_BUILD_DIR    ?= $(CURDIR)/build
export KAS_REPO_REF_DIR KAS_WORK_DIR KAS_BUILD_DIR
# kas refuses to start if KAS_WORK_DIR is absent (it does not mkdir it). Create
# it at parse time so every target is covered without a per-target prereq.
$(shell mkdir -p $(KAS_WORK_DIR))

RAUC ?= kas/rauc.yml
LOCAL ?= kas/local.yml
UBOOT_PROD_HARDENING_KAS ?= kas/uboot-prod-hardening.yml
FIT_RELEASE_TRUST_KAS ?= kas/fit-release-trust.yml
# Default to RAUC builds always; prefer local RAUC config if present
BASE ?= $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

# Export optional toggles so users can do:
#   IOTGW_ENABLE_OTBR=1 make dev|prod|bundle-*
export IOTGW_ENABLE_OTBR
export IOTGW_ENABLE_CONTAINERS
export IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
export IOTGW_ENABLE_BTF_CORE_DEV

help:
	@echo "Targets (RAUC-enabled by default):"
	@echo "  make dev                  # Build developer image"
	@echo "  make prod                 # Build production image (WIC is intermediate under release-trust; see bundle-prod-full-fit-resign)"
	@echo "  make base                 # Build base image"
	@echo "  make desktop              # Build desktop image (Wayland/Weston)"
	@echo "  -- Bundles (rootfs + kernel/DTBs) --"
	@echo "  make bundle-dev-full      # Bundle from dev image"
	@echo "  make bundle-dev-full-fit  # FIT bundle from dev image"
	@echo "  -- HSM-signing flow (detached; CI-friendly) --"
	@echo "  make sign-bootfiles-fit-yk    # Re-sign FIT in deploy tarball on YubiKey (interactive)"
	@echo "  make sign-bootfiles-fit-softhsm # Re-sign FIT in deploy tarball via SoftHSM (dev only)"
	@echo "  -- Host-side test environment (uv-based, reproducible) --"
	@echo "  make tools-venv              # Sync .venv via uv (run once or after dep bumps)"
	@echo "  make test-sign-fit           # Run signing-tool tests (no SoftHSM required)"
	@echo "  make test-sign-fit-softhsm   # Run full suite incl. SoftHSM integration tests"
	@echo "  make bundle-dev-full-fit-resign  # Re-assemble bundle with HSM-signed FIT (unattended)"
	@echo "  make bundle-base-full-fit-fast # FIT bundle from base image (OTBR off, faster)"
	@echo "  make bundle-prod-full     # Bundle from prod image"
	@echo "  make bundle-prod-full-fit # FIT bundle from prod image (release trust)"
	@echo "  make bundle-prod-full-fit-resign # Reassemble prod FIT bundle around YK-signed FIT [FINAL RELEASE ARTIFACT]"
	@echo "  make bundle-desktop-full  # Bundle from desktop image"
	@echo "  -- Bundles (rootfs-only) --"
	@echo "  make bundle-dev           # Rootfs-only bundle from dev image"
	@echo "  make bundle-desktop       # Rootfs-only bundle from desktop image"
	@echo "  -- Utilities --"
	@echo "  make layers               # Show layers for RAUC stack"
	@echo "  make parse                # Parse-only for RAUC stack"
	@echo "  make clean-lock           # Remove stale bitbake.lock"

define image_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
                   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
                   bitbake $(1)' $(BASE)
endef

base:
	$(call image_cmd,iot-gw-image-base)

dev:
	$(call image_cmd,iot-gw-image-dev)

PROD_KAS_OVERLAYS = $(BASE)$(if $(wildcard $(UBOOT_PROD_HARDENING_KAS)),:$(UBOOT_PROD_HARDENING_KAS))$(if $(wildcard $(FIT_RELEASE_TRUST_KAS)),:$(FIT_RELEASE_TRUST_KAS))

prod:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
			   bitbake iot-gw-image-prod' $(PROD_KAS_OVERLAYS)

desktop:
	# Prefer dedicated desktop KAS config; include local.yml if present for keys
	$(KAS) build $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE)) --target iot-gw-image-desktop

define bundle_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
                   BUNDLE_IMAGE_NAME=$(1) \
                   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
                   bitbake $(2)' $(BASE)
endef

bundle-dev:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle)

bundle-dev-full:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full)

bundle-dev-full-fit:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full-fit)

# Detached HSM signing flow. The build and the HSM-signing step run in
# separate processes — possibly on separate machines — so CI runners
# can drive the unattended steps without ever needing a PIN/touch.
#
# Three stages, each runnable independently:
#
#   Stage 1 — file-key signed build (UNATTENDED, CI-friendly):
#       make bundle-dev-full-fit
#     Produces the deploy tarball and a file-key-signed .raucb. No HSM,
#     no PIN, no touch. Suitable for GitHub Actions, GitLab runners, or
#     any unattended pipeline.
#
#   Stage 2 — re-sign FIT in the deploy tarball (OPERATOR-ONLY):
#       make sign-bootfiles-fit-yk [SIGN_FIT_ARGS='...']
#     Takes the deploy tarball produced by Stage 1 and re-signs the
#     embedded FIT against the PKCS#11 token. Requires PIN entry and a
#     touch on the YubiKey. Only runs on a machine with the HSM
#     physically attached (operator workstation or a hardened signing
#     server). Never runs in CI.
#
#   Stage 3 — re-assemble bundle from signed tarball (UNATTENDED):
#       make bundle-dev-full-fit-resign
#     Re-runs the bundle recipe from do_configure so the assembled
#     .raucb carries the HSM-signed FIT. No HSM interaction. Can run
#     in CI on a runner that has the signed tarball deployed to
#     DEPLOY_DIR_IMAGE (or be invoked locally by the operator after
#     Stage 2).
#
# Typical release pipeline:
#   - CI:        make bundle-dev-full-fit             → publish unsigned artifacts
#   - Operator:  fetch artifacts → make sign-bootfiles-fit-yk → publish signed tarball
#   - CI/Op:     make bundle-dev-full-fit-resign      → publish final signed .raucb
#
# SIGN_BOOTFILES_ARGS  → bootfiles-archive specific flags
#                       (e.g. --force, --archive PATH).
# SIGN_FIT_ARGS        → signing flags (e.g. --verify, --verbose,
#                       --key-name-hint NAME, --uri URI). Defaults to '--verify'.
#                       Both are passed to `sign_fit.py sign-bootfiles`
#                       which now accepts them inline (no '--' separator).
SIGN_BOOTFILES_ARGS ?=
SIGN_FIT_ARGS ?= --verify
sign-bootfiles-fit-yk:
	python3 scripts/sign_fit.py sign-bootfiles --profile yubikey-9a $(SIGN_BOOTFILES_ARGS) $(SIGN_FIT_ARGS)

# Dev signing variant for engineers without a YubiKey. Requires a
# provisioned SoftHSM token holding the iotgw-fit-softhsm-dev keypair;
# see docs/FIT_BOOT_SIGNING.md for the provisioning runbook. Only
# usable against an image that enables IOTGW_FIT_TRUST_SOFTHSM_KEY in
# kas/local.yml — never against a production Image C build.
sign-bootfiles-fit-softhsm:
	python3 scripts/sign_fit.py sign-bootfiles --profile softhsm-dev $(SIGN_BOOTFILES_ARGS) $(SIGN_FIT_ARGS)

# Host-side Python test environment (uv-based). Not used by Yocto
# builds or by the operator signing targets above; those keep running
# against the system Python with a distro-installed `python3-yaml`.
UV ?= uv
tools-venv:
	$(UV) sync

test-sign-fit:
	$(UV) run pytest scripts/tests/

test-sign-fit-softhsm:
	SOFTHSM_AVAILABLE=1 $(UV) run pytest scripts/tests/

bundle-dev-full-fit-resign:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-dev \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
			   bitbake -C do_configure iot-gw-bundle-full-fit' $(BASE)

bundle-base-full-fit-fast:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-base \
			   IOTGW_ENABLE_OTBR=0 \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
			   bitbake iot-gw-bundle-full-fit' $(BASE)

define prod_bundle_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
                   BUNDLE_IMAGE_NAME=iot-gw-image-prod \
                   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
                   bitbake $(1)' $(PROD_KAS_OVERLAYS)
endef

# Release bundles. PROD_KAS_OVERLAYS composes kas/fit-release-trust.yml,
# so both build iot-gw-image-prod with the release FIT trust profile
# (YubiKey-only DTB). bundle-prod-full-fit is the release FIT artifact —
# the prod-image equivalent of bundle-dev-full-fit, and the bundle to
# flash for issue #73 on-target validation.
bundle-prod-full:
	$(call prod_bundle_cmd,iot-gw-bundle-full)

bundle-prod-full-fit:
	$(call prod_bundle_cmd,iot-gw-bundle-full-fit)

# Reassemble the release FIT bundle around an already YubiKey-signed
# bootfiles-fit.tar.gz. Run after `make sign-bootfiles-fit-yk`; re-runs the
# bundle recipe from do_configure so the .raucb picks up the HSM-signed FIT.
# Prod equivalent of bundle-dev-full-fit-resign; keeps PROD_KAS_OVERLAYS so
# kas/fit-release-trust.yml stays active.
bundle-prod-full-fit-resign:
	$(call prod_bundle_cmd,-C do_configure iot-gw-bundle-full-fit)

bundle-desktop-full:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
			   bitbake iot-gw-bundle-full' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

bundle-desktop:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) \
			   bitbake iot-gw-bundle' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

layers:
	$(KAS) shell -c 'bitbake-layers show-layers' $(BASE)

parse:
	$(KAS) shell -c 'bitbake -p' $(BASE)

clean-lock:
	rm -f build/bitbake.lock
