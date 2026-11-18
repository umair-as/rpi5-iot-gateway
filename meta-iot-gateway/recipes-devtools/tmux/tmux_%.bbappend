FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://tmux.conf"

do_install:append() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/tmux.conf ${D}${sysconfdir}/tmux.conf
}

# CVE-2026-11623: use-after-free in image_free() (image.c), SIXEL image
# handling. image.c and image-sixel.c are compiled only under ENABLE_SIXEL
# (Makefile.am), which the recipe's sixel PACKAGECONFIG controls and leaves
# off (--disable-sixel). The status is conditional so that enabling sixel
# turns the finding back to unpatched; the fix to carry then is upstream
# commit b8434182c9ead062be8d50a1ff88e98b41108c1f (tmux 3.6b).
#   https://www.cve.org/CVERecord?id=CVE-2026-11623
#   https://security-tracker.debian.org/tracker/CVE-2026-11623
CVE_STATUS[CVE-2026-11623] = "${@bb.utils.contains('PACKAGECONFIG', 'sixel', 'unpatched', 'not-applicable-config: vulnerable image.c is built only with SIXEL support, which is disabled', d)}"
