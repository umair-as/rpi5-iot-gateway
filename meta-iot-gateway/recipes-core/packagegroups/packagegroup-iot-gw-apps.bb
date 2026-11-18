SUMMARY = "IoT GW Applications package group"
DESCRIPTION = "IoT gateway services: protocols, DB, monitoring, Node.js"
LICENSE = "MIT"

inherit packagegroup

# Avoid allarch so we can depend on dynamically renamed libs (ABI/versioned)
PACKAGE_ARCH = "${MACHINE_ARCH}"

PACKAGES = " \
    ${PN} \
    ${PN}-protocols \
    ${PN}-database \
    ${PN}-monitoring \
    ${PN}-node-runtime \
"

RDEPENDS:${PN} = " \
    ${PN}-protocols \
    ${PN}-database \
    ${PN}-monitoring \
"

# Optional slices (enable per-image as needed)
# - ${PN}-node-runtime: Node.js runtime for on-host apps

RDEPENDS:${PN}-protocols = " \
    curl \
    wget \
"

RDEPENDS:${PN}-database = " \
    sqlite3 \
"

RDEPENDS:${PN}-monitoring = " \
    sysstat \
    edge-healthd \
"

RDEPENDS:${PN}-node-runtime = " \
    nodejs \
    nodejs-npm \
"
