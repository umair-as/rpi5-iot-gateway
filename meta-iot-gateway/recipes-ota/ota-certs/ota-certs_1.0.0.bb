# SPDX-License-Identifier: MIT
#
# ota-certs: OTA mTLS certificate provisioning
#

SUMMARY = "OTA mTLS certificate provisioning"
DESCRIPTION = "Provisions device certificates for OTA update authentication. \
Supports per-device certs from /boot/iotgw/ota/ or generates development \
certificates for testing."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
RECIPE_MAINTAINER = "Umair A.S <umair-as@users.noreply.github.com>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

DEPENDS += "openssl-native"

SRC_URI = " \
    file://ota-certs-provision.sh \
    file://ota-certs-provision.service \
    file://generate-dev-cert.sh \
"

S = "${WORKDIR}"

PACKAGES =+ "${PN}-devca"

RAUC_OTA_CA_DIR ?= ""
IOTGW_ENABLE_OTA_TPM_MTLS ?= "0"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "ota-certs-provision.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

do_install() {
    # Install provisioning script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ota-certs-provision.sh ${D}${sbindir}/ota-certs-provision
    install -m 0755 ${WORKDIR}/generate-dev-cert.sh ${D}${sbindir}/ota-generate-dev-cert

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ota-certs-provision.service ${D}${systemd_system_unitdir}/
    if ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS', '1', 'true', 'false', d)}; then
        sed -i '/^\[Service\]/a Environment=OTA_CERTS_ALLOW_KEYLESS_DEVICE_CERTS=1' \
            ${D}${systemd_system_unitdir}/ota-certs-provision.service
    fi

    # Create certificate directory structure
    install -d ${D}${sysconfdir}/ota

    # Optional build-time CA seed: keeps image trust anchor aligned with the
    # authoritative OTA CA directory while runtime provisioning remains in
    # charge of device cert/key.
    if [ -n "${RAUC_OTA_CA_DIR}" ]; then
        ca_crt=""
        ca_key=""
        for c in "${RAUC_OTA_CA_DIR}/ca.crt" "${RAUC_OTA_CA_DIR}/dev-ca.crt"; do
            if [ -f "$c" ]; then
                ca_crt="$c"
                break
            fi
        done
        for k in "${RAUC_OTA_CA_DIR}/ca.key" "${RAUC_OTA_CA_DIR}/dev-ca.key"; do
            if [ -f "$k" ]; then
                ca_key="$k"
                break
            fi
        done

        if [ -z "$ca_crt" ] || [ -z "$ca_key" ]; then
            bbfatal "RAUC_OTA_CA_DIR is set (${RAUC_OTA_CA_DIR}) but CA files were not found (expected ca.crt/ca.key or dev-ca.crt/dev-ca.key)"
        fi

        if ! openssl x509 -in "$ca_crt" -noout >/dev/null 2>&1; then
            bbfatal "Invalid CA certificate in RAUC_OTA_CA_DIR: $ca_crt"
        fi

        install -m 0644 "$ca_crt" ${D}${sysconfdir}/ota/ca.crt

    fi
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
