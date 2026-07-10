SUMMARY = "IoT GW sysctl tuning for containers and MQTT"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-iotgw.conf"

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/iotgw-sysctl
    install -m 0644 ${UNPACKDIR}/90-iotgw.conf ${D}${datadir}/iotgw-sysctl/90-iotgw.conf
}

FILES:${PN} = "${datadir}/iotgw-sysctl/90-iotgw.conf"

