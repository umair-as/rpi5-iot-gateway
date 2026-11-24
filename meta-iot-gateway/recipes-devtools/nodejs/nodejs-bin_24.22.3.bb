SUMMARY = "Prebuilt Node.js binary for target"
DESCRIPTION = "Installs official prebuilt Node.js ${PV} binary for aarch64 (arm64). Builds fast by avoiding V8 compilation."
HOMEPAGE = "https://nodejs.org/"
LICENSE = "MIT & ISC & BSD-2-Clause & BSD-3-Clause & Artistic-2.0 & Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=edc0683b77d2c503217642fa000b5b31"

# Only for aarch64 targets (arm64 binaries)
COMPATIBLE_HOST = "aarch64.*-linux"

SRC_URI = "https://nodejs.org/dist/v${PV}/node-v${PV}-linux-arm64.tar.xz"
SRC_URI[sha256sum] = "6e51a2ada00f0011cc266f65d98922b403d7ad88f809ca2aa615a5fe1ce6e86c"

S = "${UNPACKDIR}/node-v${PV}-linux-arm64"

INHIBIT_DEFAULT_DEPS = "1"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

# Provide the same logical provider as the compiled recipe
PROVIDES += "nodejs"
RPROVIDES:${PN}:class-target += "nodejs"

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

# Ensure packagegroup deps on nodejs-npm are satisfied (target only)
RPROVIDES:${PN}-npm:class-target += "nodejs-npm"

# Avoid QA complaining about prebuilt binaries/paths
INSANE_SKIP:${PN} = "ldflags textrel already-stripped"
INSANE_SKIP:${PN}-npm = "ldflags textrel already-stripped"

# Prebuilt binary: declare expected runtime deps (target only) and relax file-rdeps QA
RDEPENDS:${PN}:class-target += "glibc libstdc++ libgcc"
INSANE_SKIP:${PN} += " file-rdeps"
INSANE_SKIP:${PN}-npm += " file-rdeps"

# Prebuilt upstream Node.js: track its advisories under the NVD product, not the
# recipe name, which matches no NVD product.
CVE_PRODUCT = "nodejs:node.js"
