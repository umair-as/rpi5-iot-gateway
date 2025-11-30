FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Provide improved grow-partition unit and script
SRC_URI:append = " \
    file://rauc-grow-data-partition.service \
    file://grow-data-partition.sh \
"

# grow-data-partition.sh requires bash and e2fsprogs (for e2fsck)
RDEPENDS:${PN}-grow-data-part:append = " bash e2fsprogs"

do_install:append() {
    # Override unit with our hardened version
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rauc-grow-data-partition.service \
        ${D}${systemd_system_unitdir}/rauc-grow-data-partition.service

    # Install grow helper script used by the unit
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/grow-data-partition.sh \
        ${D}${sbindir}/grow-data-partition.sh
}

# Ensure the script is placed with the grow subpackage
FILES:rauc-grow-data-part:append = " ${sbindir}/grow-data-partition.sh"

