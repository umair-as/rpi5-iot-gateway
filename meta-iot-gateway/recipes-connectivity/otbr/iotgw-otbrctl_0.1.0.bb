SUMMARY = "IoT Gateway OTBR D-Bus CLI (iotgw-otbrctl) for testing"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "git://github.com/umair-uas/iotgw-otbrctl.git;protocol=https;branch=main"
SRCREV = "${AUTOREV}"

S = "${WORKDIR}/git"

DEPENDS = "sdbus-c++"

inherit cmake

RDEPENDS:${PN} += "sdbus-c++"
RDEPENDS:${PN}:append = "${@bb.utils.contains('IOTGW_ENABLE_OTBR','1',' otbr-rpi5','',d)}"

EXTRA_OECMAKE:append = " -DIOTGW_OTBRCTL_VERSION=${PV}"
