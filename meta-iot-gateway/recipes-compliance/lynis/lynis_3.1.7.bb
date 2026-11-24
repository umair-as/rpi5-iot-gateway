# Lynis (no other layer in the stack provides lynis).

SUMMARY = "Lynis is a free and open source security and auditing tool."
HOMEPAGE = "https://cisofy.com/"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=3edd6782854304fd11da4975ab9799c1"

# Vendor tarball; extracts to 'lynis' (no version suffix).
SRC_URI = "https://downloads.cisofy.com/lynis/lynis-${PV}.tar.gz"
SRC_URI[sha256sum] = "b5314a07fd85fa3ffc7da57b508f0108ec3280d84e4af823f805d95cbbc2428c"

S = "${UNPACKDIR}/${BPN}"

inherit autotools-brokensep

do_compile[noexec] = "1"
do_configure[noexec] = "1"

do_install () {
    install -d ${D}${bindir}
    install -d ${D}${sysconfdir}/lynis
    install -m 555 ${S}/lynis ${D}${bindir}

    install -d ${D}${datadir}/lynis/db
    install -d ${D}${datadir}/lynis/plugins
    install -d ${D}${datadir}/lynis/include
    install -d ${D}${datadir}/lynis/extras

    cp -r ${S}/db/* ${D}${datadir}/lynis/db/.
    cp -r ${S}/plugins/*  ${D}${datadir}/lynis/plugins/.
    cp -r ${S}/include/* ${D}${datadir}/lynis/include/.
    cp -r ${S}/extras/*  ${D}${datadir}/lynis/extras/.
    cp ${S}/*.prf ${D}${sysconfdir}/lynis || true
}

FILES:${PN} += "${sysconfdir}/developer.prf ${sysconfdir}/default.prf"
FILES:${PN}-doc += "lynis.8 FAQ README CHANGELOG.md CONTRIBUTIONS.md CONTRIBUTORS.md"

RDEPENDS:${PN} += "procps findutils coreutils iproute2-ip iproute2-ss net-tools"
