FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://tmux.conf"

do_install:append() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/tmux.conf ${D}${sysconfdir}/tmux.conf
}
