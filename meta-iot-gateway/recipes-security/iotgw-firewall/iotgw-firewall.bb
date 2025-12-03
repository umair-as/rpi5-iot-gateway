SUMMARY = "IoT GW nftables baseline rules"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://nftables.conf"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/iotgw-firewall
    install -m 0644 ${WORKDIR}/nftables.conf ${D}${datadir}/iotgw-firewall/nftables.conf
}

FILES:${PN} = "${datadir}/iotgw-firewall/nftables.conf"

RDEPENDS:${PN} += "nftables"
