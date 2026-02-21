SUMMARY = "IoT GW Container runtime tools"
DESCRIPTION = "Container runtime and image tools for the gateway (Podman ecosystem)."
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch due to possible dynamic package renames across arches
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Runtime stack needed to run containers on target.
IOTGW_CONTAINER_RUNTIME_PACKAGES ?= " \
    podman \
    conmon \
    crun \
    netavark \
    aardvark-dns \
    slirp4netns \
    fuse-overlayfs \
    catatonit \
    packagegroup-iot-gw-containers-ops \
    container-host-config \
"

# Optional image/build tooling (adds significant Go/Rust build load).
IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS ?= "0"

RDEPENDS:${PN} = " \
    ${IOTGW_CONTAINER_RUNTIME_PACKAGES} \
"
RDEPENDS:${PN}:append = "${@bb.utils.contains('IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS','1',' buildah skopeo','',d)}"

# Optional UX toolsy to include per-image
RRECOMMENDS:${PN} += "${@bb.utils.contains('IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS','1',' podman-compose','',d)}"
