# meta-secure-core recipe installs engines-3/* into ${PN}, which captures the
# static archive libtpm2tss.a and fails staticdev QA. For gateway runtime we
# only need the shared engine module(s), so drop the static archive.
do_install:append() {
    rm -f ${D}${libdir}/engines-3/*.a || true
}
