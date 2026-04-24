.PHONY: help base dev prod desktop \
        bundle-dev bundle-dev-full bundle-dev-full-fit bundle-base-full-fit-fast bundle-prod-full bundle-desktop-full bundle-desktop \
        layers parse clean-lock

KAS ?= kas
RAUC ?= kas/rauc.yml
LOCAL ?= kas/local.yml
UBOOT_PROD_HARDENING_KAS ?= kas/uboot-prod-hardening.yml
# Default to RAUC builds always; prefer local RAUC config if present
BASE ?= $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

# Export optional toggles so users can do:
#   IOTGW_ENABLE_OTBR=1 make dev|prod|bundle-*
export IOTGW_ENABLE_OTBR
export IOTGW_ENABLE_CONTAINERS
export IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
export IOTGW_ENABLE_OBSERVABILITY

help:
	@echo "Targets (RAUC-enabled by default):"
	@echo "  make dev                  # Build developer image"
	@echo "  make prod                 # Build production image"
	@echo "  make base                 # Build base image"
	@echo "  make desktop              # Build desktop image (Wayland/Weston)"
	@echo "  -- Bundles (rootfs + kernel/DTBs) --"
	@echo "  make bundle-dev-full      # Bundle from dev image"
	@echo "  make bundle-dev-full-fit  # FIT bundle from dev image"
	@echo "  make bundle-base-full-fit-fast # FIT bundle from base image (OTBR off, faster)"
	@echo "  make bundle-prod-full     # Bundle from prod image"
	@echo "  make bundle-desktop-full  # Bundle from desktop image"
	@echo "  -- Bundles (rootfs-only) --"
	@echo "  make bundle-dev           # Rootfs-only bundle from dev image"
	@echo "  make bundle-desktop       # Rootfs-only bundle from desktop image"
	@echo "  -- Utilities --"
	@echo "  make layers               # Show layers for RAUC stack"
	@echo "  make parse                # Parse-only for RAUC stack"
	@echo "  make clean-lock           # Remove stale bitbake.lock"

define image_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
                   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
                   bitbake $(1)' $(BASE)
endef

base:
	$(call image_cmd,iot-gw-image-base)

dev:
	$(call image_cmd,iot-gw-image-dev)

prod:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
			   bitbake iot-gw-image-prod' $(if $(wildcard $(UBOOT_PROD_HARDENING_KAS)),$(BASE):$(UBOOT_PROD_HARDENING_KAS),$(BASE))

desktop:
	# Prefer dedicated desktop KAS config; include local.yml if present for keys
	$(KAS) build $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE)) --target iot-gw-image-desktop

define bundle_cmd
  $(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
                   BUNDLE_IMAGE_NAME=$(1) \
                   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
                   bitbake $(2)' $(BASE)
endef

bundle-dev:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle)

bundle-dev-full:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full)

bundle-dev-full-fit:
	$(call bundle_cmd,iot-gw-image-dev,iot-gw-bundle-full-fit)

bundle-base-full-fit-fast:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-base \
			   IOTGW_ENABLE_OTBR=0 \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
			   bitbake iot-gw-bundle-full-fit' $(BASE)

bundle-prod-full:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-prod \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
			   bitbake iot-gw-bundle-full' $(if $(wildcard $(UBOOT_PROD_HARDENING_KAS)),$(BASE):$(UBOOT_PROD_HARDENING_KAS),$(BASE))

bundle-desktop-full:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
			   bitbake iot-gw-bundle-full' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

bundle-desktop:
	$(KAS) shell -c 'BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS BUNDLE_IMAGE_NAME IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_OBSERVABILITY" \
			   BUNDLE_IMAGE_NAME=iot-gw-image-desktop \
			   IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
			   IOTGW_ENABLE_CONTAINERS=$(IOTGW_ENABLE_CONTAINERS) \
			   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
			   IOTGW_ENABLE_OBSERVABILITY=$(IOTGW_ENABLE_OBSERVABILITY) \
			   bitbake iot-gw-bundle' $(if $(wildcard kas/desktop.yml),$(if $(wildcard $(LOCAL)),kas/desktop.yml:$(LOCAL),kas/desktop.yml),$(BASE))

layers:
	$(KAS) shell -c 'bitbake-layers show-layers' $(BASE)

parse:
	$(KAS) shell -c 'bitbake -p' $(BASE)

clean-lock:
	rm -f build/bitbake.lock
