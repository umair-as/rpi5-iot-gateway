# SPDX-License-Identifier: MIT
#
# ota-certs: OTA mTLS certificate provisioning
#

SUMMARY = "OTA mTLS certificate provisioning"
DESCRIPTION = "Provisions device certificates for OTA update authentication. \
Supports per-device certs from /boot/iotgw/ota/ or generates development \
certificates for testing."
HOMEPAGE = "https://github.com/umair-uas/rpi5-iot-gateway"
RECIPE_MAINTAINER = "Umair A.S <umair-uas@users.noreply.github.com>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://ota-certs-provision.sh \
    file://ota-certs-provision.service \
    file://generate-dev-cert.sh \
"

S = "${WORKDIR}"

PACKAGES =+ "${PN}-devca"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "ota-certs-provision.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install provisioning script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ota-certs-provision.sh ${D}${sbindir}/ota-certs-provision
    install -m 0755 ${WORKDIR}/generate-dev-cert.sh ${D}${sbindir}/ota-generate-dev-cert

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ota-certs-provision.service ${D}${systemd_system_unitdir}/

    # Create certificate directory structure
    install -d ${D}${sysconfdir}/ota
}

FILES:${PN} = " \
    ${sbindir}/ota-certs-provision \
    ${systemd_system_unitdir}/ota-certs-provision.service \
    ${sysconfdir}/ota \
"

FILES:${PN}-devca = " \
    ${sbindir}/ota-generate-dev-cert \
"

RDEPENDS:${PN}-devca = " \
    bash \
    openssl \
    coreutils \
"

RDEPENDS:${PN} = " \
    bash \
    openssl \
    coreutils \
"
