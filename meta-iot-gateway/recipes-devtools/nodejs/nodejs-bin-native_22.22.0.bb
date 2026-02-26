SUMMARY = "Prebuilt Node.js binary for build host (native)"
DESCRIPTION = "Installs official prebuilt Node.js ${PV} binary for x86_64 build host to provide npm during recipe builds."
HOMEPAGE = "https://nodejs.org/"
LICENSE = "MIT & ISC & BSD-2-Clause & BSD-3-Clause & Artistic-2.0 & Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1fdf4f79da4006c3b5183fddc768f1c8"

# native should be inherited last to satisfy QA (native-last)
inherit bin_package native

COMPATIBLE_HOST = "x86_64.*-linux"

SRC_URI = "https://nodejs.org/dist/v${PV}/node-v${PV}-linux-x64.tar.xz"
SRC_URI[sha256sum] = "9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37"

S = "${WORKDIR}/node-v${PV}-linux-x64"

INHIBIT_DEFAULT_DEPS = "1"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${prefix}
    for d in bin include lib share; do
        if [ -d "$d" ]; then
            cp -r --no-preserve=ownership,mode "$d" "${D}${prefix}/"
        fi
    done

    chown -R root:root ${D}${prefix}
    find ${D}${prefix} -type d -exec chmod 0755 {} +
    find ${D}${prefix} -type f -exec chmod 0644 {} +
    for b in node npm npx corepack; do
        if [ -f ${D}${bindir}/$b ]; then chmod 0755 ${D}${bindir}/$b; fi
    done
}

# Relax QA on prebuilt binary
INSANE_SKIP:${PN} = " ldflags textrel already-stripped file-rdeps"
