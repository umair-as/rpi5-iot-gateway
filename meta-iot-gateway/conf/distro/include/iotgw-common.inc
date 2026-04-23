# IoT Gateway common distro include
# Centralizes vendor branding, versioning, SDK naming, QA policy, and RAUC defaults.

# Vendor branding
VENDOR_SHORT_NAME ?= "igw"
VENDOR_LONG_NAME ?= "IoT Gateway"

# Propagate vendor into target triplet and SDK names
TARGET_VENDOR ?= "-${VENDOR_SHORT_NAME}"

# Distro/versioning policy (override OE-Core default 'nodistro.0')
# Keep version components explicit so release policy can bump one field at a time.
IOTGW_VERSION_MAJOR ?= "0"
IOTGW_VERSION_MINOR ?= "3"
IOTGW_VERSION_PATCH ?= "0"
IOTGW_VERSION ?= "${IOTGW_VERSION_MAJOR}.${IOTGW_VERSION_MINOR}.${IOTGW_VERSION_PATCH}"
DISTRO_VERSION ?= "${VENDOR_SHORT_NAME}.${IOTGW_VERSION}"
# Default codename for this product line (override in CI if desired)
DISTRO_CODENAME ?= "rpi5"

# RAUC bundle version policy:
#   <distro-version>-<machine>-<image-track>-b<build-id>
# where image-track is derived from iot-gw-image-{dev,prod,base,...}.
# CI/release jobs may override IOTGW_BUILD_ID or RAUC_BUNDLE_VERSION directly.
IOTGW_RELEASE_TRACK ?= "${@((d.getVar('BUNDLE_IMAGE_NAME') or d.getVar('IMAGE_BASENAME') or 'iot-gw-image-unknown').replace('iot-gw-image-', ''))}"
IOTGW_BUILD_ID ?= "${@d.getVar('SOURCE_DATE_EPOCH') or '0'}"
RAUC_BUNDLE_VERSION ?= "${DISTRO_VERSION}-${MACHINE}-${IOTGW_RELEASE_TRACK}-b${IOTGW_BUILD_ID}"
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"
PREFERRED_RPROVIDER_virtual-rauc-conf ?= "rauc-conf-iotgw"

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

# SDK branding
SDK_VENDOR ?= "-${VENDOR_SHORT_NAME}sdk"
SDK_VERSION := "${DISTRO_VERSION}"
SDK_NAME ?= "${VENDOR_SHORT_NAME}-${DISTRO}-${TCLIBC}-${SDK_ARCH}-${IMAGE_BASENAME}-${TUNE_PKGARCH}"
SDKPATH ?= "/opt/${VENDOR_SHORT_NAME}-${DISTRO}/${SDK_VERSION}"

# Prefer Lynis 3.1.5 from our overlay
PREFERRED_VERSION_lynis ?= "3.1.5"

# Node.js binary provider/version policy
# Keep default on 20.x until OTBR web UI migration is fully validated.
# Override in local/product config when testing newer runtime, e.g.:
#   IOTGW_NODEJS_BIN_VERSION = "22.22.0"
PREFERRED_PROVIDER_nodejs ?= "nodejs-bin"
IOTGW_NODEJS_BIN_VERSION ?= "20.12.2"
PREFERRED_VERSION_nodejs-bin ?= "${IOTGW_NODEJS_BIN_VERSION}"
PREFERRED_VERSION_nodejs-bin-native ?= "${IOTGW_NODEJS_BIN_VERSION}"

# Policy and QA
INHERIT += "sanity"
INHERIT += "insane"
QA_LOG ?= "1"
ERROR_TO_WARN_QA ?= "version-going-backwards"


# Init system and features (single source of truth)
INIT_MANAGER ?= "systemd"
VIRTUAL-RUNTIME_init_manager ?= "systemd"
# Journald-only policy: do not pull classic syslog daemons from packagegroups.
VIRTUAL-RUNTIME_base-utils-syslog = ""
DISTRO_FEATURES:append = " systemd bluetooth virtualization usrmerge security"
# AppArmor distro feature kept for reference while LSM default decision is pending.
# Remove once SELinux is confirmed as the production default LSM.
# DISTRO_FEATURES:append = " apparmor"
# RAUC is mandatory in this distro
DISTRO_FEATURES:append = " rauc"
DISTRO_FEATURES:append = " luks"

# This unblocks systemd-creds TPM operations and cryptenroll-based flows.
PACKAGECONFIG:append:pn-systemd = " tpm2 openssl"
PACKAGECONFIG:append:pn-systemd = " pcre2 audit"
PACKAGECONFIG:append:pn-systemd = " cryptsetup cryptsetup-plugins"
PACKAGECONFIG:append:pn-cryptsetup = " luks2"

# Always use U-Boot on Raspberry Pi for RAUC boot flow
RPI_USE_U_BOOT ?= "1"

# Trim unneeded distro features (conservative defaults)
DISTRO_FEATURES:remove = " pcmcia 3g nfc ptest debuginfod sysvinit nfs"

# Exclude unused RPC portmapper (pulled in by base packagegroups)
PACKAGE_EXCLUDE:append = " rpcbind"

# If product is headless, consider also removing windowing/graphics stacks:
# DISTRO_FEATURES:remove:append = " x11 wayland vulkan opengl pulseaudio"

# Root home
ROOT_HOME ?= "/root"

# Note: DEFAULTTUNE overrides for multiple SoCs can be added when needed.

# Allow injecting Wi-Fi credentials from the shell environment without committing them
# Usage: export IOTGW_WIFI_SSID=MySSID IOTGW_WIFI_PSK=Secret && bitbake iot-gw-image-rauc
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_WIFI_SSID IOTGW_WIFI_PSK IOTGW_ENABLE_OTBR IOTGW_ENABLE_EDGE_HEALTHD"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM_SLB9672 IOTGW_TPM_DTO_OVERLAY IOTGW_ENABLE_KERNEL_NO_EFI"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_OTA_TPM_MTLS IOTGW_OTA_TPM_KEY_URI IOTGW_OTA_TPM_KEY_ENGINE IOTGW_OTA_OPENSSL_CONF"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_RAUC_STREAMING_KEY_MODE IOTGW_RAUC_PKCS11_BACKEND IOTGW_RAUC_PKCS11_TLS_KEY IOTGW_RAUC_PKCS11_MODULE IOTGW_RAUC_PKCS11_PROVIDER_PACKAGES IOTGW_TPM2_PKCS11_STORE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS IOTGW_RAUC_ENCRYPTION_KEY IOTGW_RAUC_ENCRYPTION_CERT"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_RPI_EEPROM IOTGW_ENABLE_VCIO"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_SELINUX IOTGW_ENABLE_IMA"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_OBSERVABILITY IOTGW_ENABLE_ENCRYPTED_STORE_DEV IOTGW_OBSERVABILITY_REQUIRE_NETWORK_ONLINE"
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_ENABLE_CONTAINERS IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS"
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

# Headless profile trims windowing/graphics/audio stacks
DISTRO_FEATURES:remove:headless = " x11 wayland vulkan opengl pulseaudio"

# Desktop profile: enable graphics/audio stacks, PAM and polkit (Wayland/Weston)
DISTRO_FEATURES:append:desktop = " wayland opengl vulkan pulseaudio pam polkit"

# Desktop packages (consumed by image recipes via override)
# Upstream weston-init manages the service and user/groups; we don't duplicate it.
IOTGW_DESKTOP_PACKAGES ?= "weston wayland-utils mesa libdrm"


# Optional kernel feature sets (selected via IOTGW_KERNEL_FEATURES)
# Globally enabled: networking (WireGuard/CAN/VLAN) + security (AppArmor/Seccomp/no-SCTP)
# Per-image additions via IOTGW_KERNEL_FEATURES (space or comma-separated):
#   igw_containers         - namespaces, cgroups (for podman/docker)
#   igw_compute_media      - GPU/V4L2/cameras/hugepages (for desktop/ML)
#   igw_observability_dev  - eBPF/ftrace/kprobes (dev builds only)
#   igw_no_efi             - disable kernel EFI runtime/stub surface (opt-in)
#   igw_selinux            - SELinux compiled in, AppArmor remains default LSM
#   igw_ima                - IMA measurement (PCR10, SHA256, ima-ng template)
IOTGW_KERNEL_FEATURES ?= "igw_networking_iot igw_security_prod"

# Optional TPM2 over SPI profile for Infineon SLB9672-class modules.
# Enable to pull built-in TPM kernel config and Raspberry Pi firmware overlay.
# Overlay default maps to Raspberry Pi's upstream TPM SPI overlay.
IOTGW_ENABLE_TPM_SLB9672 ?= "0"
IOTGW_TPM_DTO_OVERLAY ?= "tpm-slb9670"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672', '1', ' igw_tpm_slb9672', '', d)}"

# Optional TPM crypto provider stack (userspace integrations):
#  - tpm2-pkcs11
#  - tpm2-openssl
#  - tpm2-tss-engine
# Keep disabled by default until app/client integration is wired.
IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS ?= "0"

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
# - pkcs11: tls-key=<pkcs11:...> via configured PKCS#11 backend
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
IOTGW_TPM2_PKCS11_STORE ?= "/var/lib/tpm2_pkcs11"

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

# Optional encrypted RAUC bundle support (disabled by default):
# - build side: create `crypt` bundles and encrypt to recipient cert set
# - target side: populate /etc/rauc/system.conf [encryption] for decrypt key
IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS ?= ""
IOTGW_RAUC_ENCRYPTION_KEY ?= ""
IOTGW_RAUC_ENCRYPTION_CERT ?= ""

# Optional kernel EFI surface reduction profile for non-UEFI RPi5 boot flow.
# Enable to append igw_no_efi fragment set.
IOTGW_ENABLE_KERNEL_NO_EFI ?= "1"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_KERNEL_NO_EFI', '1', ' igw_no_efi', '', d)}"

# Optional SELinux kernel support. Compiled in alongside AppArmor; AppArmor
# remains the default LSM until meta-selinux userspace is available and policy
# is ready. Switch at runtime: lsm=selinux on the kernel cmdline.
IOTGW_ENABLE_SELINUX ?= "0"
IOTGW_KERNEL_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_SELINUX', '1', ' igw_selinux', '', d)}"

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

# Optional observability stack (native services: InfluxDB + Telegraf).
# Containerized observability is paused on Scarthgap due to Rust toolchain skew
# in netavark/aardvark-dns and will be revisited on the next Yocto LTS rebase.
IOTGW_ENABLE_OBSERVABILITY ?= "0"
# Telegraf dependency mode:
#   0: local-first startup (network.target) with runtime retries (default)
#   1: strict startup ordering via network-online.target (remote endpoints)
IOTGW_OBSERVABILITY_REQUIRE_NETWORK_ONLINE ?= "0"

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

RPI_KERNEL_DEVICETREE:raspberrypi5 = "${@bb.utils.contains_any('PREFERRED_PROVIDER_virtual/kernel', \
    'linux-iotgw-mainline linux-iotgw-mainline-fit', \
    '${IOTGW_RPI5_KERNEL_DTBS_MAINLINE}', '${IOTGW_RPI5_KERNEL_DTBS_DEFAULT}', d)}"

# Mainline providers currently do not ship the Raspberry Pi overlay dtbo set
# used by meta-raspberrypi's raspberrypi5 machine config.
python () {
    if d.getVar("MACHINE") != "raspberrypi5":
        return
    provider = (d.getVar("PREFERRED_PROVIDER_virtual/kernel") or "").strip()
    if provider in ("linux-iotgw-mainline", "linux-iotgw-mainline-fit"):
        d.setVar("RPI_KERNEL_DEVICETREE_OVERLAYS", "")
}
