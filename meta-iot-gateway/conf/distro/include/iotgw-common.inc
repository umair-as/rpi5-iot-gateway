# IoT Gateway common distro include
# Centralizes vendor branding, versioning, SDK naming, QA policy, and RAUC defaults.

# Vendor branding
VENDOR_SHORT_NAME ?= "igw"
VENDOR_LONG_NAME ?= "IoT Gateway"

# Propagate vendor into target triplet and SDK names
TARGET_VENDOR ?= "-${VENDOR_SHORT_NAME}"

# Distro/versioning (override OE-Core default 'nodistro.0')
DISTRO_VERSION = "${VENDOR_SHORT_NAME}.0.1"
# Default codename for this product line (override in CI if desired)
DISTRO_CODENAME ?= "rpi5"

# RAUC defaults (deterministic). CI may override RAUC_BUNDLE_VERSION.
RAUC_BUNDLE_VERSION ?= "r0"
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"
PREFERRED_RPROVIDER_virtual-rauc-conf ?= "rauc-conf-iotgw"

# Avoid parsing meta-rauc's reference rauc-conf which expects certs not present here
SKIP_RECIPE[rauc-conf] = "replaced with rauc-conf-iotgw"

# RAUC keyring default for device verification (bundle signing keys are set in bundle recipes or kas/local.yml)
RAUC_KEYRING_FILE ?= "dev-cert.pem"

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
DISTRO_FEATURES:append = " systemd bluetooth virtualization usrmerge security"
# RAUC is mandatory in this distro
DISTRO_FEATURES:append = " rauc"

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
IOTGW_KERNEL_FEATURES ?= "igw_networking_iot igw_security_prod"

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
