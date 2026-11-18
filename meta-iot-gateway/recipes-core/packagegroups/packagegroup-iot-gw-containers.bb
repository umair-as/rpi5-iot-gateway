SUMMARY = "IoT GW Container runtime tools"
DESCRIPTION = "Container runtime and image tools for the gateway (Podman ecosystem)."
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch due to possible dynamic package renames across arches
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Runtime stack needed to run containers on target. Containers run rootless
# as the iotgw-ctr principal (iotgw-ctr-user: account, home with the store on
# /data, linger, Quadlet directory); passt provides pasta, the rootless
# network helper (slirp4netns is not installed: BAD_RECOMMENDATIONS in
# iotgw-common.inc).
# tzdata-core: podman's tz="local" resolves the host /etc/localtime when
# configuring container timezones and hard-fails when it is absent; the
# base image ships no zoneinfo at all.
IOTGW_CONTAINER_RUNTIME_PACKAGES ?= " \
    podman \
    conmon \
    crun \
    netavark \
    aardvark-dns \
    passt \
    catatonit \
    tzdata-core \
    packagegroup-iot-gw-containers-ops \
    container-host-config \
    iotgw-ctr-user \
"

# Optional image/build tooling (adds significant Go/Rust build load).
IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS ?= "0"

RDEPENDS:${PN} = " \
    ${IOTGW_CONTAINER_RUNTIME_PACKAGES} \
"
RDEPENDS:${PN}:append = "${@bb.utils.contains('IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS','1',' buildah skopeo','',d)}"

# Optional UX toolsy to include per-image
RRECOMMENDS:${PN} += "${@bb.utils.contains('IOTGW_ENABLE_CONTAINERS_IMAGE_TOOLS','1',' podman-compose','',d)}"
