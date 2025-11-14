SUMMARY = "IoT GW Container runtime tools"
DESCRIPTION = "Container runtime and image tools for the gateway (Podman ecosystem)."
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch due to possible dynamic package renames across arches
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    podman \
    buildah \
    skopeo \
    conmon \
    crun \
    netavark \
    aardvark-dns \
    slirp4netns \
    fuse-overlayfs \
    catatonit \
    container-host-config \
"

# Optional UX toolsy to include per-image
RRECOMMENDS:${PN} += " podman-compose "
