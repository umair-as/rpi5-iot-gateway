# IoT Gateway common distro include
# Centralizes vendor branding, versioning, SDK naming, QA policy, and RAUC defaults.

# Vendor branding
VENDOR_SHORT_NAME ?= "igw"
VENDOR_LONG_NAME ?= "IoT Gateway"

# Target triplet and SDK naming stay the oe-core defaults (TARGET_VENDOR "-oe",
# SDK_VENDOR, SDK_NAME, SDKPATH): bitbake.conf assigns them before the distro
# configuration is read, so a weak assignment here would not take effect.

# Distro/versioning policy (override OE-Core default 'nodistro.0')
# Keep version components explicit so release policy can bump one field at a time.
IOTGW_VERSION_MAJOR ?= "0"
IOTGW_VERSION_MINOR ?= "7"
IOTGW_VERSION_PATCH ?= "0"
IOTGW_VERSION ?= "${IOTGW_VERSION_MAJOR}.${IOTGW_VERSION_MINOR}.${IOTGW_VERSION_PATCH}"
DISTRO_VERSION ?= "${VENDOR_SHORT_NAME}.${IOTGW_VERSION}"
# Default codename for this product line (override in CI if desired)
DISTRO_CODENAME ?= "rpi5"

# Cross-recipe CVE_STATUS (SELinux userspace fan-out). Recipe-wide false
# positives live in per-recipe bbappends; this include is only for dispositions
# that span many recipes of one project. Harmless outside the CVE/SBOM flow.
require conf/distro/include/iotgw-cve-ignores.inc
# CVE database revisions (weak defaults; inert outside the CVE/SBOM flow).
require conf/distro/include/iotgw-cve-db.inc

# RAUC bundle version policy:
#   <distro-version>-<machine>-<image-track>-b<build-id>
# where image-track is derived from iot-gw-image-{dev,prod,base,...}.
# CI/release jobs may override IOTGW_BUILD_ID or RAUC_BUNDLE_VERSION directly.
IOTGW_RELEASE_TRACK ?= "${@((d.getVar('BUNDLE_IMAGE_NAME') or d.getVar('IMAGE_BASENAME') or 'iot-gw-image-unknown').replace('iot-gw-image-', ''))}"
IOTGW_BUILD_ID ?= "${@d.getVar('SOURCE_DATE_EPOCH') or '0'}"
RAUC_BUNDLE_VERSION ?= "${DISTRO_VERSION}-${MACHINE}-${IOTGW_RELEASE_TRACK}-b${IOTGW_BUILD_ID}"
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"
PREFERRED_RPROVIDER_virtual-rauc-conf ?= "rauc-conf-iotgw"

# libnss-mdns is RPROVIDED by both avahi-libnss-mdns and mdns (mDNSResponder,
# pulled in via otbr-rpi5's RDEPENDS). This distro standardises on avahi for
# mDNS/DNS-SD (avahi-daemon ships in the images, OTBR builds with
# -DOTBR_MDNS=avahi), so pin the NSS mDNS plugin to avahi's to match the
# running resolver and resolve the multiple-provider ambiguity deterministically.
PREFERRED_RPROVIDER_libnss-mdns ?= "avahi-libnss-mdns"

# Avoid parsing meta-rauc's reference rauc-conf which expects certs not present here
SKIP_RECIPE[rauc-conf] = "replaced with rauc-conf-iotgw"
PREFERRED_VERSION_rauc ?= "1.15.2"
PREFERRED_VERSION_rauc-native ?= "1.15.2"
PREFERRED_VERSION_nativesdk-rauc ?= "1.15.2"

# RAUC keyring default for device verification (bundle signing keys are set in bundle recipes or kas/local.yml)
RAUC_KEYRING_FILE ?= "dev-cert.pem"

# Build metadata exposure policy
# Keep host build system identifier in buildinfo by default for diagnostics.
# Production images can disable this in image recipes.
IOTGW_BUILDINFO_INCLUDE_BUILD_SYS ?= "1"

SDK_VERSION := "${DISTRO_VERSION}"

# Node.js binary provider/version policy: an LTS line in support, prebuilt
# (no V8 compile). Node 24 is supported until 2028-04-30; move to the next LTS
# line before then. Only the OTBR web UI uses it (build and runtime).
PREFERRED_PROVIDER_nodejs ?= "nodejs-bin"
IOTGW_NODEJS_BIN_VERSION ?= "24.22.3"
PREFERRED_VERSION_nodejs-bin ?= "${IOTGW_NODEJS_BIN_VERSION}"
PREFERRED_VERSION_nodejs-bin-native ?= "${IOTGW_NODEJS_BIN_VERSION}"

# LLVM backends (llvm, llvm-native; rust links llvm). OE-core builds eight CPU
# backends plus LLVM_TARGETS_GPU (AMDGPU, NVPTX, SPIRV) whenever opengl or
# vulkan is a distro feature. Needed: AArch64 target, ARM, X86 build host and
# qemux86-64, BPF eBPF objects. The GPU backends serve only mesa-native's
# gallium-llvm drivers and target llvm; no image task graph contains either
# (base, dev, desktop, prod), and the RPi5's VideoCore VII driver (v3d) does
# not use LLVM. Distro-wide so all hosts share llvm and rust sstate. A change
# rebuilds both from scratch.
LLVM_TARGETS_TO_BUILD ?= "AArch64;ARM;BPF;X86"

# Policy and QA
INHERIT += "sanity"
INHERIT += "insane"
QA_LOG ?= "1"
ERROR_TO_WARN_QA ?= "version-going-backwards"

# ── FIT signed-boot policy (mandatory; the ONLY supported boot flow) ──────────
# FIT is unconditional and tracked here, so a clean checkout can never build an
# unsigned stock kernel. Operator key *paths* stay in kas/local.yml.
PREFERRED_PROVIDER_virtual/kernel = "linux-iotgw-mainline"
PREFERRED_VERSION_linux-iotgw-mainline = "6.18%"
KERNEL_BOOTCMD = "bootm"

# Keep the FIT flow isolated from meta-raspberrypi's stock kernel recipes.
BBMASK:append = " .*/meta-raspberrypi/recipes-kernel/linux/linux-raspberrypi.*\\.(bb|bbappend)"
BBMASK:append = " .*/meta-raspberrypi/recipes-kernel/linux/linux-raspberrypi-v7.*\\.(bb|bbappend)"

# Observability stack (telegraf, influxdb3-bin, the influxdb append): kept in
# the layer for the planned MQTT/InfluxDB/Telegraf deployment, but parsed and
# built only when switched on. Off, BBMASK hides recipes-observability/
# entirely; no image installs any of it yet.
IOTGW_ENABLE_OBSERVABILITY ?= "0"
BBMASK:append = "${@'' if bb.utils.to_boolean(d.getVar('IOTGW_ENABLE_OBSERVABILITY')) else ' .*/meta-iot-gateway/recipes-observability/'}"

# FIT signing algorithms (control-DTB pubkey injection + FIT config signature).
FIT_HASH_ALG = "sha256"
FIT_SIGN_ALG = "rsa2048"
FIT_GENERATE_KEYS = "0"

# Signing is REQUIRED. Default ON; iotgw-fit-signing-guard.bbclass hard-fails
# the build if this is off or no operator signing key is usable.
IOTGW_FIT_SIGNING ?= "1"
UBOOT_SIGN_ENABLE = "${@bb.utils.contains('IOTGW_FIT_SIGNING','1','1','0',d)}"

# FIT DTB trust roots (see kas/local.yml.example fit_dtb_*_trust blocks for the
# rotation pattern). Read by the kernel recipe, which injects the public keys
# into the board DTB, and by the image recipes (iotgw-fit-gate, the
# release-trust WIC warning), which check what was injected. Set distro-wide so
# both datastores see the same values. The file key defaults on so a developer
# without a YubiKey or SoftHSM builds normally; the YK and SoftHSM gates default
# off. SoftHSM trust is dev-only — never enable it on production.
IOTGW_FIT_TRUST_FILE_KEY    ?= "1"
IOTGW_FIT_TRUST_YK_KEY      ?= "0"
IOTGW_FIT_YK_KEYDIR         ?= ""
IOTGW_FIT_YK_KEYNAME        ?= "iotgw-fit-yk-2027"
IOTGW_FIT_TRUST_SOFTHSM_KEY ?= "0"
IOTGW_FIT_SOFTHSM_KEYDIR    ?= ""
IOTGW_FIT_SOFTHSM_KEYNAME   ?= "iotgw-fit-softhsm-dev"

# ── U-Boot feature tokens ────────────────────────────────────────────────────
# IOTGW_UBOOT_FEATURES is read in two recipe datastores that do not share
# variables: the u-boot recipe (builds the matching cfg/patch) and the
# rpi-bootfiles-archive-* recipe (self-heals the matching boot-critical env vars
# into the RAUC bundle). The default is set here, distro-wide, so both see the
# same tokens; a per-recipe default would leave the bootfiles recipe (which has
# none of its own) blind to it.
#
#   surface_reduce  disable unused U-Boot commands
#   fit_enforce     require signed FIT, drop legacy image format (mandatory)
#   watchdog        BCM2712 wdt (watchdog@7d200000): armed across the U-Boot
#                   RAUC/FIT boot path and the exhausted-slot halt, stopped
#                   before bootm
#
# prod adds appliance_lockdown through kas/uboot-prod-hardening.yml (a global
# :append, composed by the prod make targets); the prod hygiene gate fails the
# image when it is missing, so a prod image cannot be built without it.
IOTGW_UBOOT_FEATURES ?= "surface_reduce fit_enforce watchdog"


# Init system and features (single source of truth)
INIT_MANAGER ?= "systemd"
VIRTUAL-RUNTIME_init_manager ?= "systemd"
# Journald-only policy: do not pull classic syslog daemons from packagegroups.
VIRTUAL-RUNTIME_base-utils-syslog = ""
DISTRO_FEATURES:append = " systemd bluetooth virtualization usrmerge security"
# Container runtime: every image variant ships it (iot-gw-image-base.inc), with
# no toggle. Containers run rootless as the iotgw-ctr principal from Quadlet
# units in its user manager (packagegroup-iot-gw-containers, iotgw-ctr-user);
# the rootful engine is installed for administration but has no units. An
# image with Quadlet units but no engine builds and boots, then fails on
# hardware.
VIRTUAL-RUNTIME_container_engine ?= "podman"
VIRTUAL-RUNTIME_container_runtime ?= "crun"
VIRTUAL-RUNTIME_container_networking ?= "netavark"
VIRTUAL-RUNTIME_container_dns ?= "aardvark-dns"
# Rootless networking is pasta (passt, in the containers packagegroup); podman
# recommends slirp4netns as well, which would ship a second, unused helper.
BAD_RECOMMENDATIONS:append = " slirp4netns"
# RAUC is mandatory in this distro
DISTRO_FEATURES:append = " rauc"
DISTRO_FEATURES:append = " luks"
# SELinux is the distro's active MAC (always on). This bit both flips
# PACKAGECONFIG[selinux] in oe-core recipes (systemd, PAM, ...) and fires
# the meta-selinux bbappends. Kernel-side LSM stack: security-prod.cfg.
# Userspace/policy: packagegroup-iot-gw-selinux. Primer: docs/SELINUX.md.
DISTRO_FEATURES:append = " selinux"

# MCS refpolicy variant: full module set plus the single non-hierarchical
# sensitivity level. The container runtime (podman/netavark/container-selinux)
# relabels netns/overlay dirs with 4-field :s0 contexts; a non-MCS (3-field)
# policy rejects those at lsetxattr() with EINVAL even in permissive mode,
# breaking rootless bridge/host networking. This concrete package name must
# stay in sync with packagegroup-iot-gw-selinux's refpolicy RDEPENDS.
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"

# Boot mode of the shipped policy. DEFAULT_ENFORCING lands in
# /etc/selinux/config of the refpolicy package, which every image of a kas
# composition shares, so the mode is per composition, not per image. Every
# image boots enforcing; a composition may set IOTGW_SELINUX_MODE = "permissive"
# to collect the access surface of new software before its policy exists. The
# kernel command line is signed into the slot FIT, so recovery from a slot that
# fails under enforcing is the A/B fallback (boot counters), not a boot
# parameter.
IOTGW_SELINUX_MODE ??= "enforcing"

# Static user and group IDs. Files on /data keep their numeric owners across
# OTA updates and A/B rollback, so every system account has one fixed ID for
# all images (meta-iot-gateway/files/iotgw-passwd, iotgw-group). Dynamic
# allocation would renumber accounts whenever the package set changes. A recipe
# that adds an account without a table entry fails the build; accounts created
# by an image's EXTRA_USERS_PARAMS carry their IDs in the command itself.
# Changing an assigned ID needs a /data migration (docs/PERSISTENT_STATE.md).
USERADDEXTENSION = "useradd-staticids"
USERADD_UID_TABLES = "files/iotgw-passwd"
USERADD_GID_TABLES = "files/iotgw-group"
USERADD_ERROR_DYNAMIC = "error"
DEFAULT_ENFORCING = "${IOTGW_SELINUX_MODE}"

# Per-domain permissive is a POLICY statement (`permissive X;`), applied by the
# kernel regardless of CONFIG_SECURITY_SELINUX_DEVELOP, so the build checks the
# built store instead: iotgw-rootfs.bbclass fails the image on any permissive
# domain not listed here. This list is the staging allowlist for new domains
# whose access surface is still being collected on an enforcing trial. It must
# be EMPTY before DEFAULT_ENFORCING flips to enforcing.
IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED ?= ""

# openssl unblocks systemd-creds/cryptenroll crypto flows. The systemd `tpm2`
# PACKAGECONFIG (libtss2) is added by kas/tpm.yml, not here: tpm2-tss lives in
# meta-secure-core, which is composed only with the TPM overlay — adding the
# PACKAGECONFIG unconditionally would break non-TPM builds.
PACKAGECONFIG:append:pn-systemd = " openssl"
PACKAGECONFIG:append:pn-systemd = " pcre2 audit"
PACKAGECONFIG:append:pn-systemd = " cryptsetup cryptsetup-plugins"
PACKAGECONFIG:append:pn-cryptsetup = " luks2"

# Network management: systemd-networkd (not NetworkManager). networkd owns
# addressing/DHCP; systemd-resolved owns DNS and writes the resolv.conf stub.
# The topology (br0 bridge + eth0 port + wlan0 WiFi via wpa_supplicant) ships
# in iotgw-network-units. networkd/resolved are in systemd's default
# PACKAGECONFIG; keep them and enable via 90-iotgw.preset.
VIRTUAL-RUNTIME_net_manager = "systemd-networkd"
RESOLV_CONF = "stub-resolv"

# Always use U-Boot on Raspberry Pi for RAUC boot flow
RPI_USE_U_BOOT ?= "1"

# Trim unneeded distro features (conservative defaults).
# Wrynose (Yocto 6.0) auto-enables multiarch/opengl/ptest/vulkan/wayland by
# default (via DISTRO_FEATURES_DEFAULTS, the BACKFILL replacement). ptest and
# multiarch are stripped here for all image variants (no 32-bit userspace, no
# on-target ptest); vulkan/wayland are stripped per-profile below
# (:remove:headless), with the desktop variant re-adding them via :append:desktop.
# opengl stays on headless too: see the comment there.
DISTRO_FEATURES:remove = " pcmcia 3g nfc ptest multiarch debuginfod sysvinit nfs"

# Exclude unused RPC portmapper (pulled in by base packagegroups)
PACKAGE_EXCLUDE:append = " rpcbind"

# If product is headless, consider also removing windowing/graphics stacks:
# DISTRO_FEATURES:remove:append = " x11 wayland vulkan opengl pulseaudio"

# Root home
ROOT_HOME ?= "/root"

# Note: DEFAULTTUNE overrides for multiple SoCs can be added when needed.

# Wi-Fi interface — single source of truth. iotgw-network-units, iotgw-hardening
# (wpa_supplicant@<iface> drop-in) and the RAUC managed-path all derive from this,
# so overriding it in kas/local.yml keeps hardening + OTA management aligned.
IOTGW_WIFI_IFACE ?= "wlan0"
# Infrastructure (backbone) interface OTBR is attached to (otbr-agent -B) and
# the only interface avahi/mDNS serves. Keep in step with otbr-agent.default.
IOTGW_OTBR_INFRA_IFACE ?= "wlan0"
# Container principal: names its Quadlet directory and the firewall rule that
# keeps containers off the gateway's own services. Equal to the static id table.
IOTGW_CTR_UID ?= "968"
IOTGW_CTR_SUBID_START ?= "200000"
IOTGW_CTR_SUBID_COUNT ?= "65536"
IOTGW_CTR_SUBID_RANGE = "${IOTGW_CTR_SUBID_START}-${@int(d.getVar('IOTGW_CTR_SUBID_START')) + int(d.getVar('IOTGW_CTR_SUBID_COUNT')) - 1}"

# Network-listening systemd socket units permitted in the image, as
# "<unit>=<address>" pairs. Enforced by iotgw-listen-guard.bbclass at rootfs
# assembly, by EXACT SET EQUALITY — so a listener that appears AND one that
# silently disappears both fail the build.
#
# Empty: sshd binds its own listener (sshd.service), so the image has no
# network-listening socket unit. Its IPv4 pin is
# recipes-connectivity/openssh/files/05-iotgw-listen.conf, shipped inside
# openssh-sshd so no image can install sshd without it.
#
# Only covers socket-ACTIVATED units. A daemon that binds its own socket
# directly is asserted at runtime instead, by an on-target check
# (scripts/security/exposure-target.sh).
IOTGW_NET_LISTEN_ALLOW ?= ""

# Allow injecting Wi-Fi credentials from the shell environment without committing them
# Usage: export IOTGW_WIFI_SSID=MySSID IOTGW_WIFI_PSK=Secret && bitbake iot-gw-image-rauc
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_WIFI_SSID IOTGW_WIFI_PSK IOTGW_WIFI_IFACE IOTGW_ENABLE_OTBR"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM IOTGW_ENABLE_TPM_SLB9672 IOTGW_TPM_DTO_OVERLAY IOTGW_ENABLE_KERNEL_NO_EFI IOTGW_ENABLE_DEEPX_DXM1"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_OTA_TPM_MTLS IOTGW_OTA_TPM_KEY_URI IOTGW_OTA_TPM_KEY_ENGINE IOTGW_OTA_OPENSSL_CONF"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_RAUC_STREAMING_KEY_MODE IOTGW_RAUC_PKCS11_BACKEND IOTGW_RAUC_PKCS11_TLS_KEY IOTGW_RAUC_PKCS11_MODULE IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES IOTGW_TPM2_PKCS11_STORE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS IOTGW_RAUC_BUNDLE_RECIPIENT_BASENAME IOTGW_RAUC_ENCRYPTION_KEY IOTGW_RAUC_ENCRYPTION_CERT"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_RAUC_KEYRING_CERTS IOTGW_RAUC_ALLOWED_SIGNER_CNS IOTGW_RAUC_CHECK_PURPOSE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RPI_EEPROM IOTGW_ENABLE_VCIO"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_IMA"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_BTF_CORE_DEV IOTGW_ENABLE_ENCRYPTED_STORE_DEV"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_PSTORE_PERSIST IOTGW_ENABLE_CRASH_DEBUG_DEV"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_HW_WATCHDOG IOTGW_ENABLE_SYSTEMD_HW_WATCHDOG"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_PANIC_ON_OOPS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " BUNDLE_IMAGE_NAME"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_BUILD_ID IOTGW_VERSION_MAJOR IOTGW_VERSION_MINOR IOTGW_VERSION_PATCH"

# Prune machine features that are not relevant on Raspberry Pi 5
# Keep qemu-usermode to allow gobject-introspection typelibs generation at build time
MACHINE_FEATURES:remove = " apm"

# Profile-based feature selection (headless vs desktop)
# Default profile is headless; switch via KAS/local.conf: IOTGW_PROFILE = "desktop"
IOTGW_PROFILE ?= "headless"
OVERRIDES .= ":${IOTGW_PROFILE}"

# Headless/serial-focused default: skip vconsole setup unit to avoid
# vtcon-related startup warnings on framebuffer-less deployments.
IOTGW_DISABLE_VCONSOLE_SETUP ?= "1"

# Headless profile trims windowing/graphics/audio stacks. opengl is kept: it is
# what makes Mesa buildable, and the dev image carries Mesa's v3d driver
# (EGL/GLES/GBM on the V3D GPU, no window system). The feature is shared with
# prod, which installs no GL userspace; the prod hygiene gate
# (iotgw-rootfs.bbclass) fails the build if any reaches it.
DISTRO_FEATURES:remove:headless = " x11 wayland vulkan pulseaudio"

# Desktop profile: enable graphics/audio stacks, PAM and polkit (Wayland/Weston)
DISTRO_FEATURES:append:desktop = " wayland opengl vulkan pulseaudio pam polkit"

# ...but NOT the Xwayland X server. See PACKAGECONFIG:remove below.
#
# The desktop image was shipping xwayland 24.1.11 (9 unpatched CVEs) plus
# weston-xwayland, in an image whose own weston.ini says `xwayland=false`.
# Two things conspired:
#
#   * only the HEADLESS profile removed x11 (line above this block), so the
#     desktop profile inherited it from the wrynose DISTRO_FEATURES_DEFAULTS;
#   * weston-init.bb:20 derives its PACKAGECONFIG from that
#         PACKAGECONFIG ??= "${@bb.utils.contains('DISTRO_FEATURES', 'x11', 'xwayland', '', d)}"
#     and weston-init.bb:70 then INSERTS its own value into the config file
#         sed -i -e "/^\[core\]/a xwayland=true" .../weston.ini
#     `a` after `^[core]` appends immediately BELOW the section header — i.e.
#     ABOVE our xwayland=false — and Weston's parser takes the FIRST match for
#     a duplicated key. Our setting was shadowed, never overridden, so X11
#     clients could connect on :0 regardless of what weston.ini said.
#
# The blunt fix — DISTRO_FEATURES:remove:desktop = " x11" — was tried and
# REJECTED: pcmanfm and xdg-utils both carry REQUIRED_DISTRO_FEATURES = "x11"
# (pcmanfm via startup-notification, xdg-utils via its xprop RDEPENDS), so the
# image loses its only graphical file manager and no Wayland-native
# replacement exists in the composed layer set. Verified with a `bitbake -n`
# dependency dry run, which failed with "Nothing RPROVIDES 'xdg-utils'".
#
# So the removal is scoped to the X SERVER instead. This drops the xwayland
# package, weston-xwayland, and the weston-init sed above.
#
# KNOWN LIMITATION, do not overstate this: libX11/libxcb REMAIN in the image,
# pulled in by pcmanfm through gtk+3/startup-notification. This removes the X
# server, not the X client libraries. Taking the rest would mean dropping
# pcmanfm + xdg-utils and composing a layer that provides a Wayland-native
# file manager.
# Not scoped with a :desktop override on purpose. IOTGW_PROFILE/:desktop is set
# build-WIDE in local_conf_header, so it is not a reliable per-image guard (the
# same warning is in iot-gw-image-desktop.bb). It also is not needed: no image
# in this distro wants an X server, and weston is only built for the desktop
# profile anyway.
#
# weston's own "x11" PACKAGECONFIG goes too — that is -Dbackend-x11, the
# backend for running Weston nested INSIDE an X server, which is meaningless on
# a DRM/KMS bench machine and drags in virtual/libx11, libxcb and libxcursor as
# build deps (weston_15.0.0.bb:61).
PACKAGECONFIG:remove:pn-weston-init = "xwayland"
PACKAGECONFIG:remove:pn-weston = "xwayland x11"

# Desktop packages (consumed by image recipes via override)
# Upstream weston-init manages the service and user/groups; we don't duplicate it.
IOTGW_DESKTOP_PACKAGES ?= "weston wayland-utils mesa libdrm"


# Optional kernel feature sets (selected via IOTGW_KERNEL_FEATURES)
# Globally enabled: networking (WireGuard/CAN/VLAN) + security (SELinux LSM
# stack/Seccomp/KSPP/no-SCTP, always applied via igw_security_prod).
# Per-image additions via IOTGW_KERNEL_FEATURES (space or comma-separated):
#   igw_containers         - namespaces, cgroups (for podman/docker)
#   igw_compute_media      - GPU/V4L2/cameras/hugepages (for desktop/ML)
#   igw_observability_dev  - eBPF/ftrace/kprobes (dev builds only)
#   igw_btf_core_dev       - BTF/DWARF metadata for libbpf CO-RE lab workflows
#   igw_pstore_persist     - pstore ramoops capture stack (production-safe; default on)
#   igw_crash_debug_dev    - aggressive lab-only debug (sysrq, hung-task, panic-on-oops)
#   igw_no_efi             - disable kernel EFI runtime/stub surface (opt-in)
#   igw_ima                - IMA measurement (PCR10, SHA256, ima-ng template)
#   igw_desktop            - desktop peripherals: HDMI-CEC, USB audio, BLE HID (UHID), Logitech/Wacom
IOTGW_KERNEL_FEATURES ?= "igw_networking_iot igw_security_prod"

# pstore persistence layer — production-safe. Reserves a 1 MiB ramoops region
# in DT, builds the kernel pstore RAM backend, and bind-mounts /data-backed
# storage onto /var/lib/systemd/pstore so kernel oops/panic state survives
# reboot. No behavior change otherwise — capture infrastructure only.
IOTGW_ENABLE_PSTORE_PERSIST ?= "1"

# Aggressive crash-debug lab profile — opt-in. Adds sysrq, hung-task and
# softlockup detectors, panic-on-oops, and ftrace into pstore. Implies pstore
# persistence. Not for production fleet.
# Kernel command-line options cannot be injected at runtime under the signed FIT.
IOTGW_ENABLE_CRASH_DEBUG_DEV ?= "0"

# Effective persistence flag: crash-debug-dev always implies pstore-persist.
IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE = "${@'1' if (d.getVar('IOTGW_ENABLE_CRASH_DEBUG_DEV') == '1' or d.getVar('IOTGW_ENABLE_PSTORE_PERSIST') == '1') else '0'}"

IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_PSTORE_PERSIST_EFFECTIVE', '1', ' igw_pstore_persist', '', d)}"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_CRASH_DEBUG_DEV', '1', ' igw_crash_debug_dev', '', d)}"

# Crash-debug panic timeout (seconds), for fast post-mortem turnaround. The
# kernel-baked default (CONFIG_PANIC_TIMEOUT=30 in panic-recovery.cfg, always
# applied) is the floor that covers early-boot/pre-sysctl panics.
IOTGW_CRASH_PANIC_TIMEOUT ?= "5"
# The crash-debug command-line options are signed into the slot FIT with the
# rest of the command line (iotgw-verity-image.bbclass), so they are set here
# at build time; nothing on the device can add kernel arguments.
IOTGW_VERITY_KERNEL_ARGS:append = "${@(' panic=%s oops=panic sysrq_always_enabled=1' % (d.getVar('IOTGW_CRASH_PANIC_TIMEOUT') or '5')) if d.getVar('IOTGW_ENABLE_CRASH_DEBUG_DEV') == '1' else ''}"

# Escalate kernel oops to panic so the panic timeout above actually fires
# for kernel-thread/driver oopses (default-on for fleet posture). Override
# to "0" in kas/local.yml during BSP bring-up / bisect work to keep
# tainted-but-running kernels accessible for triage. Wires
# panic-on-oops.cfg into the kernel build.
IOTGW_ENABLE_PANIC_ON_OOPS ?= "1"

# BCM2712 hardware watchdog (default on). Mainline 6.18.37 carries BCM2712 PM
# support and exposes /dev/watchdog0 on RPi5 unconditionally, so this flag no
# longer gates a kernel patch — it is retained as the intent/dependency toggle
# for the systemd PID1 ping below. Independent of that ping, an unopened
# /dev/watchdog0 does not reboot.
IOTGW_ENABLE_HW_WATCHDOG ?= "1"

# systemd hardware watchdog integration (enabled by default).
# PID1 opens /dev/watchdog and pings it at RuntimeWatchdogSec cadence, so a
# wedged kernel/PID1 self-recovers by hardware reset. Requires
# IOTGW_ENABLE_HW_WATCHDOG=1 (or another driver source) for /dev/watchdog to
# exist. Ships the vendor drop-in via recipes-support/iotgw-systemd-watchdog
# (packaged only when this is "1").
#
# RUNTIME must stay <= the BCM2712 HW max heartbeat (bcm2835_wdt
# max_hw_heartbeat_ms ~= 16s). At <=16s systemd programs the hardware timeout
# directly and pings at RUNTIME/2 (7.5s here) — validated stable on-target.
# ABOVE 16s (e.g. 20s/30s) the kernel must *bridge* the software
# timeout past the HW max via the watchdog-core worker; the worker->PID1
# fd-open handoff is racy on BCM2712 and resets the board erratically
# (reproduced at 20s: reset in ~7-40s; 15s soaks clean). So keep RUNTIME <=15s.
# SHUTDOWN is only the shutdown-hang guard and is not on the runtime feed path,
# so >16s there is fine.
IOTGW_ENABLE_SYSTEMD_HW_WATCHDOG ?= "1"
IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC ?= "15s"
IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC ?= "30s"

# TPM hardware switch. The board carries the SLB9672 and the Makefile composes
# kas/tpm.yml (which sets this to "1") into every image. It sets the defaults of
# the TPM hardware profile and the TPM crypto providers below. The OTA updater
# TPM mTLS key and PKCS#11 RAUC streaming need TPM-backed device keys
# provisioned on the target (scripts/ota/ota-pkcs11-provision-check.sh), so
# they are separate opt-ins, off by default.
IOTGW_ENABLE_TPM ?= "0"

# Optional TPM2 over SPI profile for Infineon SLB9672-class modules.
# Enable to pull built-in TPM kernel config and Raspberry Pi firmware overlay.
# Overlay default maps to Raspberry Pi's upstream TPM SPI overlay.
IOTGW_ENABLE_TPM_SLB9672 ?= "${IOTGW_ENABLE_TPM}"
IOTGW_TPM_DTO_OVERLAY ?= "tpm-slb9670"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672', '1', ' igw_tpm_slb9672', '', d)}"

# Optional TPM crypto provider stack (userspace integrations):
#  - tpm2-pkcs11
#  - tpm2-openssl
#  - tpm2-tss-engine
IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS ?= "${IOTGW_ENABLE_TPM}"

# Optional OTA mTLS TPM key mode (ota-updater + ota-certs behavior):
# - 0: default file-key flow (/etc/ota/device.key required)
# - 1: TPM key-handle flow (keyless cert provisioning allowed; updater uses TPM key URI)
IOTGW_ENABLE_OTA_TPM_MTLS ?= "0"
IOTGW_OTA_TPM_KEY_URI ?= "handle:0x81000001"
IOTGW_OTA_TPM_KEY_ENGINE ?= "tpm2tss"
IOTGW_OTA_OPENSSL_CONF ?= "/etc/ota/openssl-tpm2.cnf"
# Effective TPM mTLS gate: auto-disable when TPM hardware/profile is disabled.
IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE ?= "${@'1' if ((d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') == '1' and (d.getVar('IOTGW_ENABLE_OTA_TPM_MTLS') or '0') == '1') else '0'}"

# RAUC streaming TLS key mode:
# - file:   tls-key=/etc/ota/device.key (default)
# - pkcs11: tls-key=<pkcs11:...> via configured PKCS#11 backend (opt-in once
#           the device keys are provisioned)
IOTGW_RAUC_STREAMING_KEY_MODE ?= "file"

# PKCS#11 backend selector used when IOTGW_RAUC_STREAMING_KEY_MODE=pkcs11:
# - tpm2:  tpm2-pkcs11 provider + TPM2 token/object
# - custom: externally supplied provider/token/object
IOTGW_RAUC_PKCS11_BACKEND ?= "tpm2"

# Built-in profile preset: TPM2-backed PKCS#11 token.
# Module selection is provided by PKCS11_MODULE_PATH env from rauc.service drop-in.
IOTGW_RAUC_PKCS11_TLS_KEY_TPM2 ?= "pkcs11:token=iotgw;object=rauc-client-key;type=private;pin-source=file:/etc/ota/pkcs11-pin"
# Module path is retained as profile metadata for tooling/provisioning flows.
# RAUC streaming itself relies on libp11 + p11-kit discovery.
IOTGW_RAUC_PKCS11_MODULE_TPM2 ?= "/usr/lib/pkcs11/libtpm2_pkcs11.so"
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_TPM2 ?= "tpm2-pkcs11"
# TPM2 PKCS#11 token DB location used by sandboxed RAUC streaming helper.
# On persistent /data (not volatile /var/lib) so the device OTA identity
# survives reboot and A/B updates.
IOTGW_TPM2_PKCS11_STORE ?= "/data/tpm2_pkcs11"

# Custom profile preset: override these in kas/local.yml for other backends.
IOTGW_RAUC_PKCS11_TLS_KEY_CUSTOM ?= ""
IOTGW_RAUC_PKCS11_MODULE_CUSTOM ?= ""
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_CUSTOM ?= ""

# Effective runtime values consumed by recipes/services.
IOTGW_RAUC_PKCS11_TLS_KEY ?= "${@d.getVar('IOTGW_RAUC_PKCS11_TLS_KEY_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
IOTGW_RAUC_PKCS11_MODULE ?= "${@d.getVar('IOTGW_RAUC_PKCS11_MODULE_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
# Provider package(s) for the active PKCS#11 backend profile.
IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES ?= "${@d.getVar('IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES_%s' % ((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').upper())) or ''}"
# Effective key mode: auto-disable TPM2 PKCS#11 path when TPM profile is off.
IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE ?= "${@'file' if ((d.getVar('IOTGW_RAUC_STREAMING_KEY_MODE') or 'file') != 'pkcs11' or (((d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').lower() == 'tpm2') and (d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') != '1')) else 'pkcs11'}"
# Internal helper gate used by OTA/RAUC recipes for TPM-only behavior.
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "${@'1' if ((d.getVar('IOTGW_RAUC_STREAMING_KEY_MODE') or 'file') == 'pkcs11' and (d.getVar('IOTGW_RAUC_PKCS11_BACKEND') or 'tpm2').lower() == 'tpm2' and (d.getVar('IOTGW_ENABLE_TPM_SLB9672') or '0') == '1') else '0'}"

# Single source of truth for "this build needs the iotgw-tpm-policy package
# (and therefore the iotgwtpm /etc/group entry)". Consumed by the
# iotgw-ota-user RDEPENDS, the ota-certs install branch that wires the
# keyless-device-certs env override, and the IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS
# entry below. Keeping these three sites in sync via one derived gate avoids
# the silent-skew failure mode where the supplementary-group reconciler
# bbfatals because iotgwtpm is missing from /etc/group.
#
# The ${@...} expression is lazy: it evaluates whenever the variable is
# queried, against the datastore at that moment. That works for the normal
# config path (local.conf / kas overlay / distro include sets the primitive
# gates, then recipes read the derived gate later). It does NOT work if a
# downstream layer sets IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE or
# IOTGW_RAUC_PKCS11_USES_TPM2 in a recipe-scoped .bbappend -- bbappends only
# mutate their own recipe's datastore, so this derived gate would evaluate
# differently in that recipe than in the image-rootfs / other-recipe context.
# Set the primitives (IOTGW_ENABLE_TPM, IOTGW_ENABLE_TPM_SLB9672,
# IOTGW_ENABLE_OTA_TPM_MTLS, IOTGW_RAUC_STREAMING_KEY_MODE,
# IOTGW_RAUC_PKCS11_BACKEND) at distro / local.conf / kas-overlay level, not
# in a bbappend.
IOTGW_NEED_TPM_POLICY ?= "${@'1' if ((d.getVar('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE') or '0') == '1' or (d.getVar('IOTGW_RAUC_PKCS11_USES_TPM2') or '0') == '1') else '0'}"

# Cross-recipe supplementary group membership applied at rootfs-postprocess.
# See meta-iot-gateway/classes/iotgw-rootfs.bbclass for the mechanism. The
# 'ota:iotgwtpm' pair fires whenever the iotgw-tpm-policy package is pulled
# in (which is what causes iotgwtpm to exist in /etc/group at all).
# HDMI screen app on the desktop image: hdmi-wave-demo, enabled at boot.
# Only the desktop image installs it.
IOTGW_ENABLE_HDMI_APPS ?= "1"

IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS ??= ""
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS += "${@'ota:iotgwtpm' if (d.getVar('IOTGW_NEED_TPM_POLICY') or '0') == '1' else ''}"
# The DX-M1 probe account (iotgw-dx-demo-probe, in every DX-M1 image through
# packagegroup-iot-gw-deepx) needs the device group of iotgw-deepx-runtime.
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS += "${@'dxdemo:dxrt' if d.getVar('IOTGW_ENABLE_DEEPX_DXM1') == '1' else ''}"

# === RAUC bundle encryption — CRYPT IS THE DEFAULT POSTURE ===
#
# This block is the ONE canonical definition of the crypt/verity decision.
# Neither iot-gw-bundle-common.inc nor rauc-conf-iotgw_1.0.bb re-declares a
# default; both read IOTGW_RAUC_BUNDLE_FORMAT_EFFECTIVE below. Duplicated `?=`
# defaults used to live in all three files, which meant a build could silently
# disagree with itself about whether the image it produced could decrypt the
# bundles it produced. There is now exactly one place to change the posture.
#
# - build side:  RAUC_BUNDLE_FORMAT = "crypt", bundle encrypted to the
#                recipient cert set before it reaches DEPLOYDIR
# - target side: /etc/rauc/system.conf gets an [encryption] stanza naming the
#                per-device decryption key
#
# Opt-out (development or compatibility testing only) — produces an
# unencrypted `verity` bundle, and an image whose system.conf carries no
# [encryption] stanza:
#
#     IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION = "0"
#
# There is deliberately NO automatic fallback: with the toggle at "1" and no
# usable recipient certificate, the build fails rather than quietly emitting a
# verity bundle that an operator could mistake for a released artifact.
IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "1"

# The one crypt/verity mapping. Both the bundle producer and the target config
# recipe read this rather than re-deriving it, so they cannot disagree.
#
# An unrecognised toggle is refused here rather than folded into "not 1".
# Mapping anything-but-1 to verity would turn a typo into a silent downgrade to
# unencrypted bundles, which is the failure this posture exists to prevent.
# bb.fatal() inside the expansion keeps that check to one line -- no class and
# no extra task -- and fires in whichever recipe expands the value.
#
# No .strip(): the consumers in iot-gw-bundle-common.inc compare the raw value
# in shell, so accepting " 1 " here would resolve the format to crypt while
# those comparisons took the disabled branch. Exact means exact.
IOTGW_RAUC_BUNDLE_FORMAT_EFFECTIVE = "${@{'1': 'crypt', '0': 'verity'}.get(d.getVar('IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION')) or bb.fatal('IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION must be exactly 1 (encrypted crypt bundles, the default) or 0 (verity opt-out); got %r' % (d.getVar('IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION'),))}"

# Recipient identity (build host, PUBLIC certificate only — never the key).
# Defaults to the device leaf issued by the OTA CA that RAUC_OTA_CA_DIR already
# names, so an operator who has followed the OTA cert runbook does not have to
# configure the same directory twice. Unset RAUC_OTA_CA_DIR leaves this empty,
# and the build then fails with an actionable message rather than guessing.
#
# May name a PEM holding SEVERAL certificates: `rauc encrypt` loads every
# certificate found in the file and envelopes the bundle to all of them
# (rauc 1.15.2, src/signature.c:cms_encrypt -> load_certs_from_file).
IOTGW_RAUC_BUNDLE_RECIPIENT_BASENAME ?= "device-filekey"
IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= "${@((d.getVar('RAUC_OTA_CA_DIR') or '').rstrip('/') + '/' + (d.getVar('IOTGW_RAUC_BUNDLE_RECIPIENT_BASENAME') or 'device-filekey') + '.crt') if (d.getVar('RAUC_OTA_CA_DIR') or '') else ''}"

# Declared here so the recipient expansion above is always resolvable. The
# ota-certs recipe declares the same `?=`; whichever parses first wins and both
# agree on "".
RAUC_OTA_CA_DIR ?= ""

# Target-side decryption identity (paths ON THE DEVICE, not on the build host).
# These match what ota-certs-provision installs into /etc/ota.
#
# The key is REQUIRED by RAUC: with an enveloped CMS and no key configured,
# rauc 1.15.2 aborts in src/bundle.c with "Encrypted bundle detected, but no
# decryption key given."
#
# The cert is OPTIONAL — verified in source, not inferred from the variable
# name: src/signature.c:cms_decrypt() guards the cert load with `if (certfile)`
# and passes NULL through to CMS_decrypt(), which then tries the key against
# every RecipientInfo. It is defaulted anyway because ota-certs-provision
# always installs device.crt alongside device.key, and naming it makes
# recipient selection deterministic instead of trial-and-error. Set it to ""
# on a device that holds the key but not the certificate.
IOTGW_RAUC_ENCRYPTION_KEY ?= "/etc/ota/device.key"
IOTGW_RAUC_ENCRYPTION_CERT ?= "/etc/ota/device.crt"

# Optional kernel EFI surface reduction profile for non-UEFI RPi5 boot flow.
# Enable to append igw_no_efi fragment set.
IOTGW_ENABLE_KERNEL_NO_EFI ?= "1"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_KERNEL_NO_EFI', '1', ' igw_no_efi', '', d)}"

# SELinux is the always-on default MAC — not an opt-in feature. The kernel
# LSM stack lives in security-prod.cfg (applied on every image via
# igw_security_prod), userspace/policy in packagegroup-iot-gw-selinux, and
# the DISTRO_FEATURES/refpolicy/enforcing wiring above. See docs/SELINUX.md.

# Optional IMA measurement support. Requires TPM for replay-protected log.
# Measurement-only by default (no appraise) — safe without signed xattrs.
IOTGW_ENABLE_IMA ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_IMA', '1', ' igw_ima', '', d)}"

# Optional Raspberry Pi EEPROM tooling stack (rpi-eeprom + policy wrapper).
# Keep enabled by default for gateway fleet maintenance; developers can disable
# it for lean bring-up images and when VCIO carry patches are not desired.
IOTGW_ENABLE_RPI_EEPROM ?= "1"

# VCIO (/dev/vcio) enables vcgencmd and full rpi-eeprom-update status path.
# Default follows EEPROM tooling gate, but can be overridden explicitly.
IOTGW_ENABLE_VCIO ?= "${IOTGW_ENABLE_RPI_EEPROM}"

# Mainline RPi5 DTB note:
# - Firmware `dtparam=` keys must exist in DTB `__overrides__`.
# - Current mainline bcm2712-rpi-5-b path exports rtc/rtc_bbat_vchg, but not
#   generic `spi`, `i2c1`, or `i2c_arm`.
# - Keep peripheral enablement explicit via DTO overlays and DTS changes.
# - Do not append `dtparam=spi=on` here; it is ignored on this path and adds
#   early-boot noise.
RPI_EXTRA_CONFIG:append = "${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672', '1', '\\ndtoverlay=%s\\n' % d.getVar('IOTGW_TPM_DTO_OVERLAY'), '', d)}"

# Optional BTF/CO-RE lab kernel metadata gate. Kept separate from generic
# observability so profiles can choose one or both without coupling.
IOTGW_ENABLE_BTF_CORE_DEV ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_BTF_CORE_DEV', '1', ' igw_btf_core_dev', '', d)}"

# DEEPX DX-M1 PCIe NPU accelerator. TWO SEPARATE GATES, deliberately not one:
#   1. layer availability  — compose kas/deepx.yml (makes meta-deepx-m1 parse)
#   2. feature enablement  — this toggle: the kernel symbol whitelist, the
#                            PCIe ASPM cmdline argument, and
#                            packagegroup-iot-gw-deepx in every image
#                            (iot-gw-image-base.inc).
# kas/deepx.yml sets the toggle; the Makefile composes it for base, dev and
# desktop. Prod composes neither until the module-signing key is protected.
IOTGW_ENABLE_DEEPX_DXM1 ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_DEEPX_DXM1', '1', ' igw_deepx_dxm1', '', d)}"

# Runtime root dm-verity — the only root flow, like signed FIT boot; there is
# no toggle. Each A/B slot carries an ext4 image with an appended dm-verity
# hash tree, and the root hash is authenticated by the signed per-slot FIT: its
# device tree holds the whole verity table as the kernel command line, and
# U-Boot boots that device tree with the environment `bootargs` cleared. A
# corrupted or substituted root then fails closed and the RAUC boot counter
# falls back to the other slot. See iotgw-verity-image.bbclass.
#
# Devices still on the pre-verity ext4 slot layout must be reflashed; the
# bundle hook refuses to install onto a non-raw root slot.
IOTGW_KERNEL_FEATURES:append = " igw_rootfs_verity"

# Optional dev TPM/LUKS loopback store (/data/encstore). Keep opt-in to avoid
# boot-time/setup overhead on images where encrypted-store testing is not active.
IOTGW_ENABLE_ENCRYPTED_STORE_DEV ?= "0"

# Raspberry Pi 5 DTB policy by kernel provider:
# - Default to Model B only (smallest artifact set for rpi5 deployments).
# - Enable CM5 DTBs explicitly when building a shared/fleet image.
# - mainline bring-up providers currently ship only the rpi-5-b DTB.
IOTGW_RPI5_INCLUDE_CM5_DTBS ?= "0"
IOTGW_RPI5_KERNEL_DTBS_DEFAULT ?= "broadcom/bcm2712-rpi-5-b.dtb"
IOTGW_RPI5_KERNEL_DTBS_DEFAULT:append = "${@bb.utils.contains('IOTGW_RPI5_INCLUDE_CM5_DTBS', '1', ' broadcom/bcm2712-rpi-cm5-cm5io.dtb broadcom/bcm2712-rpi-cm5-cm4io.dtb broadcom/bcm2712-rpi-cm5l-cm5io.dtb broadcom/bcm2712-rpi-cm5l-cm4io.dtb', '', d)}"
IOTGW_RPI5_KERNEL_DTBS_MAINLINE ?= "broadcom/bcm2712-rpi-5-b.dtb"

# linux-iotgw-mainline is the only kernel provider; it ships only the
# rpi-5-b DTB and none of meta-raspberrypi's overlay dtbo set.
RPI_KERNEL_DEVICETREE:raspberrypi5 = "${IOTGW_RPI5_KERNEL_DTBS_MAINLINE}"
RPI_KERNEL_DEVICETREE_OVERLAYS:raspberrypi5 = ""
