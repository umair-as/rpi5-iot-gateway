# Distrust emSign ECC Root CA - G3 (eMudhra) in the target trust store.
#
# Eight eMudhra intermediates (6 TLS, 2 code signing) have recoverable private
# keys. They chain to roots this bundle does
# not carry (emSign Root TLS/CS CA - G3, and a Sectigo cross-sign from AAA
# Certificate Services), but emSign ECC Root CA - G3 cross-signs emSign Root
# TLS CA - G3. So a server that sends that cross-certificate gets a chain from a
# compromised intermediate up to a root this bundle trusts. Browsers block the
# intermediates through their own revocation channels; a Debian-derived
# ca-certificates bundle has none, and Mozilla is removing trust in this root.
#
# The file is removed and its line marked `!` (Debian's disable syntax), so a
# later `update-ca-certificates` on the device does not bring it back either.
# Target only: the native/SDK trust stores used at build time are untouched.
#
# oe-core master carries the same distrust as a backport of Debian's
# blacklist change (oe-core c5098a70749, "ca-certificates: Disable compromised
# CA certificates"). It also blacklists "Comodo AAA Services root", which is in
# certdata.txt but not trusted for server auth, so it never reaches this
# bundle. Remove this bbappend once the pinned wrynose oe-core carries that
# backport; the build warns when the certificate is no longer there to remove.

IOTGW_CA_DISTRUST ?= "mozilla/emSign_ECC_Root_CA_-_G3.crt"

do_install:append:class-target () {
    for crt in ${IOTGW_CA_DISTRUST}; do
        if [ ! -e ${D}${datadir}/ca-certificates/$crt ]; then
            bbwarn "ca-certificates: $crt is no longer in the upstream bundle; drop it from IOTGW_CA_DISTRUST (and this bbappend if the list is empty)"
            continue
        fi
        rm -f ${D}${datadir}/ca-certificates/$crt
        sed -i -e "s|^$crt\$|!$crt|" ${D}${sysconfdir}/ca-certificates.conf
        grep -qx "!$crt" ${D}${sysconfdir}/ca-certificates.conf \
            || bbfatal "ca-certificates: failed to disable $crt in ca-certificates.conf"
    done
}
