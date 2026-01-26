SUMMARY = "OpenThread Border Router OCI Container Image for Raspberry Pi 5"
DESCRIPTION = "Builds an OCI container image for OTBR on RPi5, loadable into Podman/Docker"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/BSD-3-Clause;md5=550794465ba0ec5312d6919e203a55f9"

# Mark this as a container build
OTBR_CONTAINER_BUILD = "1"

# Define image types - container is required for oci
IMAGE_FSTYPES = "container oci"

# Inherit image classes
inherit image
inherit image-oci

# Minimal base packages for container + OTBR (pull in runtime deps via RDEPENDS)
IMAGE_INSTALL = " \
    base-files \
    base-passwd \
    netbase \
    busybox \
    otbr-rpi5 \
"

# Optional debug tools (enable with OTBR_CONTAINER_DEBUG = "1")
OTBR_CONTAINER_DEBUG ?= "0"
IMAGE_INSTALL:append = "${@bb.utils.contains('OTBR_CONTAINER_DEBUG','1',' iproute2 iputils-ping procps','',d)}"

# Minimal container configuration
IMAGE_FEATURES = ""
IMAGE_LINGUAS = ""
NO_RECOMMENDATIONS = "1"
# Ensure kernel modules/firmware are not pulled in via machine recommends/autoload
RRECOMMENDS:${PN} = ""
PACKAGE_EXCLUDE += "kernel-module-* kernel-modules linux-firmware *-firmware"
BAD_RECOMMENDATIONS += "kernel-module-* kernel-modules linux-firmware *-firmware"

# Neutralize machine-level extras for this container image to avoid
# dragging kernel and modules into the build graph
MACHINE_ESSENTIAL_EXTRA_RDEPENDS = ""
MACHINE_ESSENTIAL_EXTRA_RRECOMMENDS = ""
MACHINE_EXTRA_RRECOMMENDS = ""
KERNEL_MODULE_AUTOLOAD = ""

# Allow build without specific kernel
IMAGE_CONTAINER_NO_DUMMY = "1"

# Disable SDK and package tasks for container images
deltask do_populate_sdk
deltask do_populate_sdk_ext

# Workaround /var/volatile
ROOTFS_POSTPROCESS_COMMAND += "rootfs_fixup_var_volatile ; "
rootfs_fixup_var_volatile () {
    install -m 1777 -d ${IMAGE_ROOTFS}/${localstatedir}/volatile/tmp
    install -m 755 -d ${IMAGE_ROOTFS}/${localstatedir}/volatile/log
}

# Entrypoint script (copy directly into the rootfs of the container image)
SRC_URI = "file://entrypoint.sh"

# For image recipes, place files into ${IMAGE_ROOTFS}, not ${D}
ROOTFS_POSTPROCESS_COMMAND += "otbr_install_entrypoint; "
otbr_install_entrypoint() {
    install -d ${IMAGE_ROOTFS}/
    install -m 0755 ${WORKDIR}/entrypoint.sh ${IMAGE_ROOTFS}/entrypoint.sh
}

# OCI Image Configuration
OCI_IMAGE_TAG = "latest"
OCI_IMAGE_RUNTIME_UID = "0"
OCI_IMAGE_WORKINGDIR = "/"

# Command to run when container starts
OCI_IMAGE_ENTRYPOINT = "/entrypoint.sh"
OCI_IMAGE_ENTRYPOINT_ARGS = ""

# Expose OTBR web interface port
OCI_IMAGE_PORTS = "80/tcp 8080/tcp"

# Environment variables
OCI_IMAGE_ENV_VARS = "OTBR_INFRA_IF=eth0"
OCI_IMAGE_ENV_VARS += " OTBR_RCP_BUS=ttyACM0"

# Labels
OCI_IMAGE_LABELS = "io.openthread.otbr.version=1.0"
OCI_IMAGE_LABELS += "io.openthread.otbr.platform=rpi5"
