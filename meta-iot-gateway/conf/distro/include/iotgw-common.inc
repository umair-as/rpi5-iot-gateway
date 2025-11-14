# IoT Gateway common distro include
# Centralizes vendor branding, versioning, SDK naming, QA policy, and RAUC defaults.

# Vendor branding
VENDOR_SHORT_NAME ?= "igw"
VENDOR_LONG_NAME ?= "IoT Gateway"

# Propagate vendor into target triplet and SDK names
TARGET_VENDOR ?= "-${VENDOR_SHORT_NAME}"

# Distro/versioning
DISTRO_VERSION ??= "${VENDOR_SHORT_NAME}.0.1"
# Default codename for this product line (override in CI if desired)
DISTRO_CODENAME ?= "rpi5"

# RAUC defaults (deterministic). CI may override RAUC_BUNDLE_VERSION.
RAUC_BUNDLE_VERSION ?= "r0"
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"
PREFERRED_RPROVIDER_virtual-rauc-conf ?= "rauc-conf-iotgw"

# Avoid parsing meta-rauc's reference rauc-conf which expects certs not present here
SKIP_RECIPE[rauc-conf] = "replaced with rauc-conf-iotgw"

# RAUC keyring/cert defaults (can be overridden per product)
RAUC_KEYRING_FILE ?= "dev-cert.pem"
RAUC_CERT_FILE ?= "dev-cert.pem"
RAUC_KEY_FILE ?= "dev-key.pem"

# SDK branding
SDK_VENDOR ?= "-${VENDOR_SHORT_NAME}sdk"
SDK_VERSION := "${DISTRO_VERSION}"
SDK_NAME ?= "${VENDOR_SHORT_NAME}-${DISTRO}-${TCLIBC}-${SDK_ARCH}-${IMAGE_BASENAME}-${TUNE_PKGARCH}"
SDKPATH ?= "/opt/${VENDOR_SHORT_NAME}-${DISTRO}/${SDK_VERSION}"

# Policy and QA
INHERIT += "sanity"
INHERIT += "insane"
QA_LOG ?= "1"
ERROR_TO_WARN_QA ?= "version-going-backwards"


# Init system and features (single source of truth)
INIT_MANAGER ?= "systemd"
VIRTUAL-RUNTIME_init_manager ?= "systemd"
DISTRO_FEATURES:append = " systemd bluetooth virtualization usrmerge"
# Enable RAUC feature only when explicitly requested
DISTRO_FEATURES:append = "${@bb.utils.contains('IOTGW_ENABLE_RAUC','1',' rauc','',d)}"

# Trim unneeded distro features (conservative defaults)
DISTRO_FEATURES:remove = " pcmcia 3g nfc ptest debuginfod sysvinit"

# If product is headless, consider also removing windowing/graphics stacks:
# DISTRO_FEATURES:remove:append = " x11 wayland vulkan opengl pulseaudio"

# Root home
ROOT_HOME ?= "/root"

# Note: DEFAULTTUNE overrides for multiple SoCs can be added when needed.

# Allow injecting Wi-Fi credentials from the shell environment without committing them
# Usage: export IOTGW_WIFI_SSID=MySSID IOTGW_WIFI_PSK=Secret && bitbake iot-gw-image-rauc
BB_ENV_PASSTHROUGH_ADDITIONS .= " IOTGW_WIFI_SSID IOTGW_WIFI_PSK"
BB_ENV_PASSTHROUGH_ADDITIONS .= " BUNDLE_IMAGE_NAME"

# Prune machine features that are not relevant on Raspberry Pi 5
# Keep qemu-usermode to allow gobject-introspection typelibs generation at build time
MACHINE_FEATURES:remove = " apm"

# Profile-based feature selection (headless vs desktop)
# Default profile is headless; switch via KAS/local.conf: IOTGW_PROFILE = "desktop"
IOTGW_PROFILE ?= "headless"
OVERRIDES .= ":${IOTGW_PROFILE}"

# Headless profile trims windowing/graphics/audio stacks
DISTRO_FEATURES:remove:headless = " x11 wayland vulkan opengl pulseaudio"

# Desktop profile enables graphics/audio stacks
DISTRO_FEATURES:append:desktop = " wayland opengl vulkan pulseaudio"

# Desktop packages (consumed by image recipes via override)
IOTGW_DESKTOP_PACKAGES ?= "weston weston-init wayland-utils mesa libdrm"

# Optional kernel feature sets (enable fragments via OVERRIDES)
# Example (dev):   IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_observability_dev"
# Example (prod):  IOTGW_KERNEL_FEATURES = "igw_compute_media igw_containers igw_networking_iot igw_security_prod"
IOTGW_KERNEL_FEATURES ?= ""
OVERRIDES .= "${@':' + ':'.join((d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split()) if d.getVar('IOTGW_KERNEL_FEATURES') else ''}"
