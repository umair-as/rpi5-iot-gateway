SUMMARY = "Prebuilt Node.js binary for target"
DESCRIPTION = "Installs official prebuilt Node.js ${PV} binary for aarch64 (arm64). Builds fast by avoiding V8 compilation."
HOMEPAGE = "https://nodejs.org/"
LICENSE = "MIT & ISC & BSD-2-Clause & BSD-3-Clause & Artistic-2.0 & Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=9a7fcce64128730251dbc58aa41b4674"

# Only for aarch64 targets (arm64 binaries)
COMPATIBLE_HOST = "aarch64.*-linux"

SRC_URI = "https://nodejs.org/dist/v${PV}/node-v${PV}-linux-arm64.tar.xz"
# SHA256 of the official prebuilt linux-arm64 tarball for v${PV}
SRC_URI[sha256sum] = "b5fc7983fb9506b8c3de53dfa85ff63f9f49cedc94984e29e4c89328536ba4b9"

S = "${WORKDIR}/node-v${PV}-linux-arm64"

INHIBIT_DEFAULT_DEPS = "1"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

# Provide the same logical provider as the compiled recipe
PROVIDES += "nodejs"
RPROVIDES:${PN} += "nodejs"

inherit bin_package

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${prefix}
    # Copy without preserving ownership/perms to avoid host uid/gid leaking
    for d in bin include lib share; do
        if [ -d "$d" ]; then
            cp -r --no-preserve=ownership,mode "$d" "${D}${prefix}/"
        fi
    done

    # Normalize ownership and permissions
    chown -R root:root ${D}${prefix}
    find ${D}${prefix} -type d -exec chmod 0755 {} +
    find ${D}${prefix} -type f -exec chmod 0644 {} +
    # Ensure executables are executable
    for b in node npm npx corepack; do
        if [ -f ${D}${bindir}/$b ]; then chmod 0755 ${D}${bindir}/$b; fi
    done
}

PACKAGES =+ "${PN}-npm"

# Main runtime: node binary and shared tree except npm
FILES:${PN} += " \
    ${bindir}/node \
    ${bindir}/corepack \
    ${libdir}/node_modules/corepack \
    ${prefix}/include \
    ${prefix}/share \
    ${libdir}/node_modules \
"

# NPM split
FILES:${PN}-npm = " \
    ${bindir}/npm \
    ${bindir}/npx \
    ${libdir}/node_modules/npm \
"

# Ensure packagegroup deps on nodejs-npm are satisfied
RPROVIDES:${PN}-npm += "nodejs-npm"

# Avoid QA complaining about prebuilt binaries/paths
INSANE_SKIP:${PN} = "ldflags textrel already-stripped"
INSANE_SKIP:${PN}-npm = "ldflags textrel already-stripped"

# Prebuilt binary: declare expected runtime deps and relax file-rdeps QA
RDEPENDS:${PN} += "glibc libstdc++ libgcc"
INSANE_SKIP:${PN} += " file-rdeps"
INSANE_SKIP:${PN}-npm += " file-rdeps"
