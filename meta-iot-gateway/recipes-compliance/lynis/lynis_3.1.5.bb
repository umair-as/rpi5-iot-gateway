# Lynis 3.1.5 recipe (override for meta-security)
# Fetch from GitHub releases (asset tarball) instead of cisofy top-level.

SUMMARY = "Lynis is a free and open source security and auditing tool."
HOMEDIR = "https://cisofy.com/"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3edd6782854304fd11da4975ab9799c1"

# Use vendor downloads site for 3.1.5 (stable asset name)
SRC_URI = "https://downloads.cisofy.com/lynis/lynis-${PV}.tar.gz"

# TODO: set the correct sha256 after first fetch or provide known value
# BitBake will print the expected line; paste it here.
SRC_URI[sha256sum] = "8d2c6652ba60116a82514522b666ca77293f4bfc69f1e581028769f7ebb52ba4"

# The GitHub release tarball extracts to lynis-${PV}
# Vendor tarball extracts to 'lynis' (no version suffix)
S = "${WORKDIR}/${BPN}"

inherit autotools-brokensep

do_compile[noexec] = "1"
do_configure[noexec] = "1"

do_install () {
    install -d ${D}/${bindir}
    install -d ${D}/${sysconfdir}/lynis
    install -m 555 ${S}/lynis ${D}/${bindir}

    install -d ${D}/${datadir}/lynis/db
    install -d ${D}/${datadir}/lynis/plugins
    install -d ${D}/${datadir}/lynis/include
    install -d ${D}/${datadir}/lynis/extras

    cp -r ${S}/db/* ${D}/${datadir}/lynis/db/.
    cp -r ${S}/plugins/*  ${D}/${datadir}/lynis/plugins/.
    cp -r ${S}/include/* ${D}/${datadir}/lynis/include/.
    cp -r ${S}/extras/*  ${D}/${datadir}/lynis/extras/.
    cp ${S}/*.prf ${D}/${sysconfdir}/lynis || true
}

FILES:${PN} += "${sysconfdir}/developer.prf ${sysconfdir}/default.prf"
FILES:${PN}-doc += "lynis.8 FAQ README CHANGELOG.md CONTRIBUTIONS.md CONTRIBUTORS.md"

RDEPENDS:${PN} += "procps findutils coreutils iproute2-ip iproute2-ss net-tools"
