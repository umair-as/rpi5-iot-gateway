.PHONY: help base dev prod desktop \
        bundle-dev-full bundle-prod-full bundle-desktop-full bundle-desktop \
        layers parse clean-lock kernel-hardening-check khc-target

KAS ?= kas
RAUC ?= kas/rauc.yml
LOCAL ?= kas/local.yml
# Default SSH host for target helper commands
HOST ?= root@iotgw
# Default to RAUC builds always; prefer local RAUC config if present
BASE ?= $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

# Export optional toggles so users can do:
#   IOTGW_ENABLE_OTBR=1 make dev|prod|bundle-*
export IOTGW_ENABLE_OTBR

help:
	@echo "Targets (RAUC-enabled by default):"
	@echo "  make dev                  # Build developer image"
	@echo "  make prod                 # Build production image"
	@echo "  make base                 # Build base image"
	@echo "  make desktop              # Build desktop image (Wayland/Weston)"
	@echo "  -- Bundles (rootfs + kernel/DTBs) --"
	@echo "  make bundle-dev-full      # Bundle from dev image"
	@echo "  make bundle-prod-full     # Bundle from prod image"
	@echo "  make bundle-desktop-full  # Bundle from desktop image"
	@echo "  -- Bundles (rootfs-only) --"
	@echo "  make bundle-desktop       # Rootfs-only bundle from desktop image"
	@echo "  -- Security --"
	@echo "  make kernel-hardening-check # Check kernel config hardening (build)"
	@echo "  make khc-target HOST=ip     # Check hardening on target via /proc/config.gz"
	@echo "  -- Utilities --"
	@echo "  make layers               # Show layers for RAUC stack"
	@echo "  make parse                # Parse-only for RAUC stack"
	@echo "  make clean-lock           # Remove stale bitbake.lock"

base:
	$(KAS) build $(BASE)

dev:
	$(KAS) build $(BASE) --target iot-gw-image-dev

prod:
	$(KAS) build $(BASE) --target iot-gw-image-prod

desktop:
	# Prefer dedicated desktop KAS config; include local.yml if present for keys
	$(KAS) build $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE)) --target iot-gw-image-desktop

define bundle_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR" \
                   BUNDLE_IMAGE_NAME=$(1) \
                   IOTGW_ENABLE_OTBR=$$IOTGW_ENABLE_OTBR \
                   bitbake $(2)' $(BASE)
endef

bundle-dev-full:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full)

bundle-prod-full:
	$(call bundle_cmd,iot-gw-image-prod,iot-gw-bundle-full)

bundle-desktop-full:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$$IOTGW_ENABLE_OTBR \
			   bitbake iot-gw-bundle-full' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

bundle-desktop:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$$IOTGW_ENABLE_OTBR \
			   bitbake iot-gw-bundle' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

layers:
	$(KAS) shell -c 'bitbake-layers show-layers' $(BASE)

parse:
	$(KAS) shell -c 'bitbake -p' $(BASE)

clean-lock:
	rm -f build/bitbake.lock

kernel-hardening-check:
	@echo "Building kernel-hardening-checker-native..."
	@$(KAS) shell -c 'bitbake kernel-hardening-checker-native' $(BASE)
	@echo ""
	@echo "Running kernel hardening checker on current kernel config..."
	@$(KAS) shell -c 'bash -lc "cd .. && ./scripts/khc-build.sh"' $(BASE) || true
	@echo ""
	@echo "Tip: Review CONFIG options marked [FAIL] and consider enabling them in kernel fragments"

khc-target:
	@if [ -z "$(HOST)" ]; then echo "Usage: make khc-target HOST=user@ip"; exit 1; fi; \
	ssh -o StrictHostKeyChecking=no $(HOST) 'zcat /proc/config.gz 2>/dev/null | kernel-hardening-checker -c - -m verbose || echo "Either /proc/config.gz or kernel-hardening-checker missing on target"'
