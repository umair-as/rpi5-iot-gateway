## Common base include for IoT Gateway images (RPi5)

# Core inheritance shared by all image variants
inherit core-image iotgw-rootfs iotgw-listen-guard extrausers
inherit iotgw-rauc-image iotgw-fit-gate iotgw-module-sig-gate

# Runtime root dm-verity: the only root flow (see iotgw-verity-image.bbclass).
inherit iotgw-verity-image

require iotgw-preinit-boot.inc

# Label the rootfs with SELinux file contexts at do_rootfs (runs setfiles
# against refpolicy-mcs's file_contexts). Without this, files ship as
# unlabeled_t and the first boot pays a slow full autorelabel. RAUC OTA
# slots inherit labels because the bundled rootfs is built with this class.
IMAGE_CLASSES += "selinux-image"

# Include centralized user/group definitions
require iotgw-users.inc

# Avoid redundant image formats
IMAGE_FSTYPES:remove = "ext3"

# Common baseline features
IMAGE_FEATURES += " \
    ssh-server-openssh \
"

# Headless-first default: avoid degraded state from static vconsole setup unit.
# Desktop profile can override this to "0" if VT keyboard setup is required.
IOTGW_DISABLE_VCONSOLE_SETUP ?= "1"

# Keep upstream RAUC mark-good flow enabled.
IOTGW_DISABLE_RAUC_MARK_GOOD ?= "0"
IOTGW_AUDIT_RULE_IMMUTABLE ?= "1"

# Desktop profile can include splash
IMAGE_FEATURES:append:desktop = " splash"

# Common packages across all variants. packagegroup-iot-gw-security (sysctl
# hardening, module blacklist, core-dump/limits policy, tmpfs mount options,
# service hardening drop-ins, audit rules) belongs to the base, not to a tier:
# a tier-level install leaves the other tiers unhardened. The prod hygiene gate
# requires its files (iotgw-rootfs.bbclass).
#
# The DX-M1 driver and runtime (not the demos) go into every image built with
# IOTGW_ENABLE_DEEPX_DXM1 = 1: base, dev and desktop compose kas/deepx.yml
# through the Makefile. Prod does not compose it until the module-signing key
# is protected (docs/DEEPX_DXM1.md).
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-base \
    ${@bb.utils.contains('IOTGW_ENABLE_DEEPX_DXM1', '1', 'packagegroup-iot-gw-deepx', '', d)} \
    packagegroup-iot-gw-hwtools \
    packagegroup-iot-gw-apps \
    packagegroup-iot-gw-selinux \
    packagegroup-iot-gw-containers \
    packagegroup-iot-gw-security \
    iotgw-banner \
    iotgw-network-units \
    iotgw-sysctl \
    iotgw-journald \
    iotgw-log-persist \
    ${@bb.utils.contains('DISTRO_FEATURES', 'bluetooth', 'iotgw-bluetooth-persist', '', d)} \
    iotgw-firewall \
    iotgw-systemd-presets \
    iotgw-nftables \
    iotgw-sshd-hardening \
    nftables \
    figlet \
    wpa-supplicant \
    kernel-modules \
    linux-firmware-rpidistro-bcm43455 \
"

# systemd 259's `systemctl preset-all` emits a "Failed to preset all unit:
# Unit <X> is masked" line for a masked unit that carries a preset directive,
# which the rootfs log_check counts as an error. Of the units this image masks
# (see iotgw-rootfs.bbclass), only systemd-networkd-wait-online trips this — the
# others are masked by mechanisms that don't run through preset-all — so the log
# carries exactly one such notice; filter it. NB: IMAGE_LOG_CHECK_EXCLUDES splits
# on literal spaces, so the regex uses \s, never a literal space.
IMAGE_LOG_CHECK_EXCLUDES += "Failed\sto\spreset\sall\sunit.*is\smasked"
