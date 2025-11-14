FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Apply a tiny learning patch that prints a boot-time message
SRC_URI:append = " file://0001-igw-hello-on-boot.patch"

# Base kernel config fragments (always included)
SRC_URI:append = " \
    file://fragments/branding.cfg \
    file://fragments/storage-filesystems.cfg \
    file://fragments/ikconfig.cfg \
"

# Optional fragments toggled via OVERRIDES using IOTGW_KERNEL_FEATURES
# Enable by setting IOTGW_KERNEL_FEATURES (space or comma-separated) to include
# one or more of: igw_compute_media igw_containers igw_networking_iot igw_observability_dev igw_security_prod
SRC_URI:append:igw_compute_media = " file://fragments/compute-media.cfg"
SRC_URI:append:igw_containers = " file://fragments/containers-cgroups.cfg"
SRC_URI:append:igw_networking_iot = " file://fragments/networking-iot.cfg"
SRC_URI:append:igw_observability_dev = " file://fragments/observability-dev.cfg"
SRC_URI:append:igw_security_prod = " file://fragments/security-prod.cfg"
