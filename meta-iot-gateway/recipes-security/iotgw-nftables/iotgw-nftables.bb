SUMMARY = "IoT Gateway nftables baseline service"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://iotgw-nftables.service \
           file://iotgw-nftables-fallback.sh \
          "

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-nftables.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "nftables"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-nftables.service ${D}${systemd_system_unitdir}/
    # ExecStopPost= helper: loads a fail-closed ruleset when the baseline
    # failed to load (see the unit and the script header).
    install -d ${D}${libexecdir}/iotgw
    install -m 0755 ${UNPACKDIR}/iotgw-nftables-fallback.sh \
        ${D}${libexecdir}/iotgw/iotgw-nftables-fallback
    sed -i -e 's/@IOTGW_CTR_UID@/${IOTGW_CTR_UID}/g' \
        -e 's/@IOTGW_CTR_SUBID_RANGE@/${IOTGW_CTR_SUBID_RANGE}/g' \
        ${D}${libexecdir}/iotgw/iotgw-nftables-fallback
    if grep -q '@[A-Z_]*@' ${D}${libexecdir}/iotgw/iotgw-nftables-fallback; then
        bbfatal "iotgw-nftables: unexpanded placeholder in the fallback ruleset"
    fi
}

FILES:${PN} = "${systemd_system_unitdir}/iotgw-nftables.service \
               ${libexecdir}/iotgw/iotgw-nftables-fallback \
              "
