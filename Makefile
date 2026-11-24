.DEFAULT_GOAL := help

KAS ?= kas
UV  ?= uv

# === Shared-layer build mechanism (git-alternates; see kas/local.yml.example) ===
# KAS_REPO_REF_DIR points at a shared bare-repo cache scoped per Yocto release
# (layers-wrynose). kas clones each layer into .kas/ (gitignored) using those
# repos as git alternates, and the SHA pins in rpi5.yml/kas/*.yml are still
# enforced. An absent ref-dir falls back to full clones. It is host-specific:
# set it in the gitignored scripts/env.local.sh or export it yourself.
# KAS_WORK_DIR keeps layer clones out of the repo root; KAS_BUILD_DIR keeps the
# bitbake build dir at ./build. Both may be overridden (isolated worktrees and
# the agent-build launcher rely on that).
KAS_REPO_REF_DIR ?=
KAS_WORK_DIR     ?= $(CURDIR)/.kas
KAS_BUILD_DIR    ?= $(CURDIR)/build
export KAS_WORK_DIR KAS_BUILD_DIR
ifneq ($(strip $(KAS_REPO_REF_DIR)),)
export KAS_REPO_REF_DIR
endif

# === Composition: one table, used by every target that runs kas ===
# BASE is the operator's kas/local.yml when present (it carries the signing
# keys, caches and host settings), else the tracked RAUC stack.
RAUC  ?= kas/rauc.yml
LOCAL ?= kas/local.yml
BASE  ?= $(if $(wildcard $(LOCAL)),$(LOCAL),$(RAUC))

DEEPX_KAS                ?= kas/deepx.yml
DESKTOP_KAS              ?= kas/desktop.yml
UBOOT_PROD_HARDENING_KAS ?= kas/uboot-prod-hardening.yml
FIT_RELEASE_TRUST_KAS    ?= kas/fit-release-trust.yml
CVE_KAS                  ?= kas/cve.yml

# The DX-M1 card is part of the platform: base and dev compose kas/deepx.yml,
# and kas/desktop.yml includes it (the desktop is the AI demo station). Prod
# stays without it until the module-signing key is protected
# (docs/DEEPX_DXM1.md). Prod composes the U-Boot hardening and the release FIT
# trust profile; both are required, never silently dropped.
#
# The desktop composition is pinned here because kas/desktop.yml never
# includes kas/local.yml (no signing key: u-boot do_configure fails) and both
# files may assign IOTGW_KERNEL_FEATURES with `=`, where the last file kas
# emits wins.
STACK_base    = $(BASE):$(DEEPX_KAS)
STACK_dev     = $(BASE):$(DEEPX_KAS)
STACK_desktop = $(BASE):$(DESKTOP_KAS)
STACK_prod    = $(BASE):$(UBOOT_PROD_HARDENING_KAS):$(FIT_RELEASE_TRUST_KAS)
empty :=
space := $(empty) $(empty)
IMAGES  := base dev desktop prod
BUNDLES := dev desktop prod

# IMAGE selects the composition for bundle, sbom-cve, parse, layers, info,
# shell and stack. A makefile assignment beats the environment, so an IMAGE the
# calling shell exports is ignored (unless make -e); `make <target> IMAGE=...`
# sets it. unexport keeps both selectors out of the commands' environment.
IMAGE := dev
SUITE := all
unexport IMAGE SUITE

# Every target shares one build directory, and compositions differ per target:
# never run two of them at once.
.NOTPARALLEL:

stack = $(STACK_$(1))
# Literal comparisons: findstring has no wildcard, so `%` in a selector
# matches nothing. one_of: $(1) is exactly one word, without surrounding
# whitespace, equal to an element of $(2).
eq     = $(and $(findstring $(1),$(2)),$(findstring $(2),$(1)))
one_of = $(if $(and $(filter 1,$(words $(1))),$(call eq,$(1),$(strip $(1)))),$(strip $(foreach x,$(2),$(if $(call eq,$(x),$(1)),$(x)))))

# Selector checks run in the recipes, so `help` works whatever was passed.
# $(1) = the image the target builds (fixed image targets only).
define check_selectors
	$(if $(SBOM_CVE_IMAGE),$(error SBOM_CVE_IMAGE is replaced by IMAGE=<$(subst $(space),|,$(IMAGES))>, e.g. make sbom-cve IMAGE=prod))
	$(if $(IMAGE_KAS),$(error IMAGE_KAS is replaced by IMAGE=<$(subst $(space),|,$(IMAGES))>, e.g. make shell IMAGE=desktop))
	$(if $(call one_of,$(IMAGE),$(IMAGES)),,$(error IMAGE='$(IMAGE)' is not one of: $(IMAGES)))
	$(if $(1),$(if $(and $(filter command line,$(origin IMAGE)),$(filter-out $(1),$(IMAGE))),$(error $@ builds IMAGE=$(1); drop IMAGE=$(IMAGE) or use a target that takes IMAGE=)))
endef

# Every file of a composition (plus $(2), e.g. the reporting overlay) must
# exist before kas starts.
define check_stack
	@for f in $(subst :, ,$(call stack,$(1))) $(2); do \
	    test -f "$$f" || { echo "$@: missing kas file '$$f' in the $(1) composition"; exit 1; }; \
	done
endef

# dev/desktop/prod kernels differ but share work-shared kernel-build-artifacts.
# After a build in another composition, make-mod-scripts keeps a current stamp
# for an artifacts tree the other kernel has since recreated, and dx-driver
# then fails with "No rule to make target 'modules'". Cleaning it first costs a
# kernel `make prepare` and changes no task signature. Prod has no out-of-tree
# module, so it skips the reset.
mod_scripts_reset = $(if $(filter prod,$(1)),,bitbake make-mod-scripts -c clean && )

# Optional feature toggles, e.g. IOTGW_ENABLE_OTBR=1 make dev
export IOTGW_ENABLE_OTBR
export IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS
export IOTGW_ENABLE_BTF_CORE_DEV
export IOTGW_ENABLE_DEEPX_DXM1

# One kas + bitbake invocation for every kas target. Exports the IOTGW_ENABLE_*
# toggles into the kas shell env and whitelists them (plus BUNDLE_IMAGE_NAME
# for bundles) for bitbake passthrough.
#   $(1) = command(s) run in the kas shell (an `a && b` chain shares the env)
#   $(2) = kas composition
#   $(3) = BUNDLE_IMAGE_NAME (bundles only)
define iotgw_bitbake
  $(KAS) shell -c 'export BB_ENV_PASSTHROUGH_ADDITIONS="$$BB_ENV_PASSTHROUGH_ADDITIONS$(if $(3), BUNDLE_IMAGE_NAME) IOTGW_ENABLE_OTBR IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS IOTGW_ENABLE_BTF_CORE_DEV IOTGW_ENABLE_DEEPX_DXM1" \
                   $(if $(3),BUNDLE_IMAGE_NAME=$(3)) IOTGW_ENABLE_OTBR=$(IOTGW_ENABLE_OTBR) \
                   IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) \
                   IOTGW_ENABLE_BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV); \
                   $(1)' $(2)
endef

# kas refuses to run if KAS_WORK_DIR is absent; order-only prerequisite of
# every kas target, so help/test/info touch nothing on a fresh tree.
$(KAS_WORK_DIR):
	@mkdir -p $@

.PHONY: help info $(IMAGES) bundle sign-slot-fits-yk sign-slot-fits-softhsm \
        sbom-cve cve-report sbom-report kernel-hardening-report \
        test preflight tools-venv shell stack parse layers clean-lock hooks

## Images
base: ## base image (DX-M1 stack)
dev: ## development image (DX-M1 stack)
desktop: ## desktop lab image, NOT hardened: Weston + DX-M1 on-screen demo
prod: ## production image (U-Boot hardening + release FIT trust; no DX-M1 yet)
$(IMAGES): | $(KAS_WORK_DIR)
	$(call check_selectors,$@)
	$(call check_stack,$@)
	$(call iotgw_bitbake,$(call mod_scripts_reset,$@)bitbake iot-gw-image-$@,$(call stack,$@))

## Bundles
# Full-FIT only: the bundle carries the rootfs and both signed slot FITs. A
# rootfs-only bundle is unsafe with DX-M1: the module-signing key is per kernel
# build unless IOTGW_MODULE_SIG_KEY_FILE is set, and bundle-hooks-fit.sh's
# kernel/module pairing guard is fail-open without a bootfiles archive.
# BUNDLE_IMAGE_NAME names the bundle after its image in DEPLOY_DIR_IMAGE.
# IMAGE=prod is the release artifact: run it after `make sign-slot-fits-yk`;
# its assembly gate refuses file-signed slot FITs.
bundle: | $(KAS_WORK_DIR) ## RAUC bundle (rootfs + slot FITs) for IMAGE=dev|desktop|prod
	$(call check_selectors)
	$(if $(filter $(IMAGE),$(BUNDLES)),,$(error bundle: IMAGE=$(IMAGE) has no bundle; one of: $(BUNDLES)))
	$(call check_stack,$(IMAGE))
	$(call iotgw_bitbake,$(call mod_scripts_reset,$(IMAGE))bitbake iot-gw-bundle-full-fit,$(call stack,$(IMAGE)),iot-gw-image-$(IMAGE))

## Signing (operator: PIN + touch; never a prerequisite of another target)
# Re-sign an image's two dm-verity slot FITs (<image>.fitImage-a/-b) as a pair:
# stage 2 of the release flow in docs/FIT_BOOT_SIGNING.md, between `make prod`
# and `make bundle IMAGE=prod`.
SLOT_FITS_IMAGE     ?= iot-gw-image-prod
SLOT_FITS_MACHINE   ?= raspberrypi5
SLOT_FITS_DEPLOY     = $(KAS_BUILD_DIR)/tmp/deploy/images/$(SLOT_FITS_MACHINE)
SIGN_SLOT_FITS_ARGS ?=
SIGN_SLOT_FITS = $(UV) run python scripts/fit-signing/sign_fit.py sign-slot-fits \
	--image $(SLOT_FITS_IMAGE)-$(SLOT_FITS_MACHINE).rootfs --deploy-dir $(SLOT_FITS_DEPLOY) \
	--archive $(SLOT_FITS_DEPLOY)/bootfiles-fit.tar.gz $(SIGN_SLOT_FITS_ARGS)
sign-slot-fits-yk: ## re-sign the slot FITs on the YubiKey (SLOT_FITS_IMAGE=, default prod)
	$(SIGN_SLOT_FITS) --profile yubikey-9a
# libsofthsm2 finds its token store via SOFTHSM2_CONF; default to the in-repo
# dev token, an operator value in the environment still wins.
sign-slot-fits-softhsm: export SOFTHSM2_CONF ?= $(CURDIR)/keys/dev/softhsm/softhsm2.conf
sign-slot-fits-softhsm: ## same via SoftHSM (dev only)
	$(SIGN_SLOT_FITS) --profile softhsm-dev

## SBOM / CVE
# Builds IMAGE with kas/cve.yml composed onto the composition that image ships
# in, so a prod scan reports the prod image's contents. Opt-in: report
# generation is slow.
sbom-cve: | $(KAS_WORK_DIR) ## image + SPDX SBOM + CVE report for IMAGE=base|dev|desktop|prod
	$(call check_selectors)
	$(call check_stack,$(IMAGE),$(CVE_KAS))
	$(call iotgw_bitbake,$(call mod_scripts_reset,$(IMAGE))bitbake iot-gw-image-$(IMAGE),$(call stack,$(IMAGE)):$(CVE_KAS))

# Host-side, read-only readers over the sbom-cve-check deploy artifacts. They
# resolve the dated report (not the undated symlink) and warn on a broken
# cohort or a newer image; CVE_REPORT_ARGS='--strict --require-latest' fails.
CVE_REPORT_ARGS  ?=
SBOM_REPORT_ARGS ?=
cve-report: ## summarise the CVE report (CVE_REPORT_ARGS=)
	python3 scripts/sbom-cve/cve-report.py $(CVE_REPORT_ARGS)
sbom-report: ## summarise the SBOM: license inventory + HIGH-risk review (SBOM_REPORT_ARGS=)
	python3 scripts/sbom-cve/sbom-report.py $(SBOM_REPORT_ARGS)

kernel-hardening-report: | $(KAS_WORK_DIR) ## kernel-hardening-checker on the prod kernel .config (report only)
	$(call check_stack,prod)
	$(call iotgw_bitbake,bitbake virtual/kernel -c iotgw_khc_report,$(call stack,prod))

## Checks
# Host test suites (no build). SUITE=all runs every suite; SOFTHSM=1 adds the
# SoftHSM integration tests of the signing tool.
TEST_sign-fit  := scripts/fit-signing/tests/
TEST_sbom-cve  := scripts/sbom-cve/tests/
TEST_kernel    := scripts/kernel/tests/
TEST_boot      := scripts/ota/tests/ scripts/preinit/tests/ scripts/sshd/tests/
TEST_selinux   := scripts/selinux/tests/
TEST_preflight := scripts/preflight/tests/
TEST_host-tools := scripts/tpm/tests/ scripts/lib/tests/
TEST_tooling   := scripts/tests/
TEST_SUITES    := sign-fit sbom-cve kernel boot selinux preflight host-tools tooling
test: ## host test suites (SUITE=all|sign-fit|sbom-cve|kernel|boot|selinux|preflight|host-tools|tooling, SOFTHSM=1)
	$(if $(call one_of,$(SUITE),all $(TEST_SUITES)),,$(error SUITE='$(SUITE)' is not one of: all $(TEST_SUITES)))
	$(if $(filter 1,$(SOFTHSM)),SOFTHSM_AVAILABLE=1 )$(UV) run pytest $(foreach s,$(if $(filter all,$(SUITE)),$(TEST_SUITES),$(SUITE)),$(TEST_$(s)))

# Map the changed paths to the cheapest checks that exercise them, before an
# image build. The bitbake tier refuses to start while a build runs.
PREFLIGHT_ARGS ?=
preflight: ## cheapest checks for what changed (PREFLIGHT_ARGS=--bitbake adds BitBake tasks)
	python3 scripts/preflight/preflight.py $(PREFLIGHT_ARGS)

# Host-side Python env (uv) for the signing tools and tests; builds don't use it.
tools-venv: ## sync .venv via uv (once, or after dependency bumps)
	$(UV) sync

## Inspection
# Interactive kas shell in IMAGE's composition, for ad-hoc bitbake runs
# (bitbake-getvar, -c <task>, -e). No command text is passed through make.
# IOTGW_ENABLE_* toggles are not forwarded: inside the shell, export the
# toggle and add its name to BB_ENV_PASSTHROUGH_ADDITIONS.
shell: | $(KAS_WORK_DIR) ## interactive kas shell in IMAGE's composition (default dev)
	$(call check_selectors)
	$(call check_stack,$(IMAGE))
	$(KAS) shell $(call stack,$(IMAGE))

# IMAGE's kas composition, machine-readable (scripts/preflight uses it).
stack: ## print IMAGE's kas composition
	$(call check_selectors)
	$(info $(call stack,$(IMAGE)))
	@:

parse: | $(KAS_WORK_DIR) ## parse-only check in IMAGE's composition (cheapest validation)
	$(call check_selectors)
	$(call check_stack,$(IMAGE))
	$(call iotgw_bitbake,bitbake -p,$(call stack,$(IMAGE)))

layers: | $(KAS_WORK_DIR) ## bitbake-layers show-layers in IMAGE's composition
	$(call check_selectors)
	$(call check_stack,$(IMAGE))
	$(call iotgw_bitbake,bitbake-layers show-layers,$(call stack,$(IMAGE)))

info: ## effective IMAGE, composition, directories and toggles (no build)
	$(call check_selectors)
	@echo "image:        $(IMAGE) (iot-gw-image-$(IMAGE))"
	@echo "composition:  $(call stack,$(IMAGE))"
	@echo "build dir:    $(KAS_BUILD_DIR)"
	@echo "work dir:     $(KAS_WORK_DIR)"
	@echo "ref dir:      $(or $(KAS_REPO_REF_DIR),(none: full clones))"
	@echo "toggles:      OTBR=$(IOTGW_ENABLE_OTBR) CONTAINERS_IMAGE_TOOLS=$(IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS) BTF_CORE_DEV=$(IOTGW_ENABLE_BTF_CORE_DEV) DEEPX_DXM1=$(IOTGW_ENABLE_DEEPX_DXM1)"

## Housekeeping
# A held bitbake.lock means a live server; removing it lets a second server
# start on the same TMPDIR. BitBake takes the lock with flock(2) and then
# checks that the locked inode is still the one at the path
# (bb.utils.lockfile). Do the same: lock fd 9, unlink only if the path still
# names that inode. While fd 9 holds the lock, no server can lock or unlink it.
clean-lock: ## remove KAS_BUILD_DIR's bitbake.lock if no BitBake server holds it
	@L="$(KAS_BUILD_DIR)/bitbake.lock"; \
	if [ ! -e "$$L" ]; then echo "no $$L: nothing to clean"; exit 0; fi; \
	exec 9<"$$L" || exit 1; \
	if ! flock -n 9; then \
	    echo "$$L is held by a live BitBake server ($$(tr -d '\n' < "$$L")); stop it with bitbake -m"; exit 1; fi; \
	if [ "$$(stat -L -c %d:%i /dev/fd/9)" != "$$(stat -c %d:%i "$$L" 2>/dev/null)" ]; then \
	    echo "$$L was replaced while locking it; run clean-lock again"; exit 1; fi; \
	rm -f "$$L" && echo "removed stale $$L"

# core.hooksPath is per-clone local config: a fresh clone has the private-key
# guard and the commit-msg check off until this runs. Idempotent.
hooks: ## enable the repo git hooks (once per clone)
	@git config core.hooksPath scripts/hooks
	@echo "core.hooksPath -> scripts/hooks"
	@echo "  pre-commit  : refuse staged private-key / keys/ material"
	@echo "  commit-msg  : enforce the Conventional Commit subject and body cap (AGENTS.md)"

help: ## this list
	@awk 'BEGIN { FS = ":.*## " } \
	    /^## / { sub(/^## /, ""); printf "\n%s\n", $$0; next } \
	    /^[a-z][a-zA-Z0-9_-]*:.*## / { printf "  make %-26s %s\n", $$1, $$2 }' $(firstword $(MAKEFILE_LIST))
	@echo ""
	@echo "Settings:"
	@echo "  IMAGE=base|dev|desktop|prod     composition for bundle, sbom-cve, parse, layers, info, shell, stack (default dev)"
	@echo "  IOTGW_ENABLE_OTBR=1, IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS=1, IOTGW_ENABLE_BTF_CORE_DEV=1   optional features"
	@echo "  KAS_BUILD_DIR=, KAS_WORK_DIR=   alternate build / layer directories"
	@echo "Long builds: scripts/agent-build/agent-build.py (docs/AGENT_BUILDS.md)."
