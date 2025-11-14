.PHONY: help base dev prod dev-rauc prod-rauc desktop-dev-rauc \
        bundle bundle-dev bundle-prod bundle-full bundle-dev-full bundle-prod-full \
        layers parse clean-lock

KAS ?= kas
BASE ?= rpi5.yml
RAUC ?= kas/rauc.yml
DESKTOP ?= kas/desktop.yml
LOCAL ?= kas/local.yml

help:
	@echo "Targets:"
	@echo "  make base                 # Build base image (headless)"
	@echo "  make dev                  # Build developer image"
	@echo "  make prod                 # Build production image"
	@echo "  make dev-rauc             # Build developer image with RAUC"
	@echo "  make prod-rauc            # Build production image with RAUC"
	@echo "  make desktop-dev-rauc     # Build dev+RAUC with desktop overlay"
	@echo "  -- Bundles (rootfs-only) --"
	@echo "  make bundle               # Standard image"
	@echo "  make bundle-dev           # Dev image"
	@echo "  make bundle-prod          # Prod image"
	@echo "  -- Bundles (rootfs+kernel) --"
	@echo "  make bundle-full          # Standard image"
	@echo "  make bundle-dev-full      # Dev image"
	@echo "  make bundle-prod-full     # Prod image"
	@echo "  -- Utilities --"
	@echo "  make layers               # Show layers for RAUC overlay"
	@echo "  make parse                # Parse-only with RAUC overlay"
	@echo "  make clean-lock           # Remove stale bitbake.lock"

base:
	$(KAS) build $(BASE)

dev:
	$(KAS) shell -c 'bitbake iot-gw-image-dev' $(BASE)

prod:
	$(KAS) shell -c 'bitbake iot-gw-image-prod' $(BASE)

dev-rauc:
	$(KAS) build $(RAUC) --target iot-gw-image-dev

prod-rauc:
	$(KAS) build $(RAUC) --target iot-gw-image-prod

desktop-dev-rauc:
	$(KAS) build $(RAUC):$(DESKTOP) --target iot-gw-image-dev

# Internal helper to avoid duplication
# Use LOCAL if it exists, otherwise fall back to RAUC
KAS_BUNDLE = $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

define bundle_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME" \
                   BUNDLE_IMAGE_NAME=$(1) \
                   bitbake $(2)' $(KAS_BUNDLE)
endef

# Bundles (parameterized by image name)
bundle:
	$(call bundle_cmd,iot-gw-image,iot-gw-bundle)

# Parameterized bundle builds (avoid extra KAS files)
bundle-dev:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle)

bundle-prod:
	$(call bundle_cmd,iot-gw-image-prod,iot-gw-bundle)

bundle-full:
	$(call bundle_cmd,iot-gw-image,iot-gw-bundle-full)

bundle-dev-full:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full)

bundle-prod-full:
	$(call bundle_cmd,iot-gw-image-prod,iot-gw-bundle-full)

layers:
	$(KAS) shell -c 'bitbake-layers show-layers' $(RAUC)

parse:
	$(KAS) shell -c 'bitbake -p' $(RAUC)

clean-lock:
	rm -f build/bitbake.lock
