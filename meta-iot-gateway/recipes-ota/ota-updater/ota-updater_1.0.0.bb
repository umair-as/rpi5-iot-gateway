# SPDX-License-Identifier: MIT
#
# ota-updater: Lightweight OTA update polling daemon for RAUC
#

SUMMARY = "OTA update polling daemon for RAUC"
DESCRIPTION = "Polls an HTTPS manifest endpoint using mTLS authentication, \
compares installed vs available bundle versions, and triggers RAUC installation \
when updates are available."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
RECIPE_MAINTAINER = "Umair A.S <umair-as@users.noreply.github.com>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://ota-update-check.sh \
    file://ota-updater.service \
    file://ota-updater.timer \
    file://ota-updater.conf.in \
    file://ota-updater-tpm.service.conf \
    file://openssl-tpm2.cnf \
    file://ota-updater.tmpfiles.conf \
"

S = "${WORKDIR}"

IOTGW_OTA_SERVER_URL ?= "https://updates.example.com:8443"
IOTGW_OTA_MANIFEST_PATH ?= "/api/v1/manifest.json"
IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE ?= "0"
IOTGW_OTA_TPM_KEY_URI ?= "handle:0x81000001"
IOTGW_OTA_TPM_KEY_ENGINE ?= "tpm2tss"
IOTGW_OTA_OPENSSL_CONF ?= "/etc/ota/openssl-tpm2.cnf"

IOTGW_OTA_DEVICE_KEY_URI = "${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', d.getVar('IOTGW_OTA_TPM_KEY_URI') or '', '', d)}"
IOTGW_OTA_DEVICE_KEY_ENGINE = "${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', d.getVar('IOTGW_OTA_TPM_KEY_ENGINE') or 'tpm2tss', 'tpm2tss', d)}"
IOTGW_OTA_OPENSSL_CONF_VALUE = "${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', d.getVar('IOTGW_OTA_OPENSSL_CONF') or '', '', d)}"

# -----------------------------------------------------------------------------
# Installation
# -----------------------------------------------------------------------------
do_install() {
    # Install the check script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ota-update-check.sh ${D}${sbindir}/ota-update-check

    # Install systemd units
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ota-updater.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/ota-updater.timer ${D}${systemd_system_unitdir}/

    # Install configuration
    install -d ${D}${sysconfdir}/ota
    sed -e "s|@IOTGW_OTA_SERVER_URL@|${IOTGW_OTA_SERVER_URL}|g" \
        -e "s|@IOTGW_OTA_MANIFEST_PATH@|${IOTGW_OTA_MANIFEST_PATH}|g" \
        -e "s|@IOTGW_OTA_DEVICE_KEY_URI@|${IOTGW_OTA_DEVICE_KEY_URI}|g" \
        -e "s|@IOTGW_OTA_DEVICE_KEY_ENGINE@|${IOTGW_OTA_DEVICE_KEY_ENGINE}|g" \
        -e "s|@IOTGW_OTA_OPENSSL_CONF@|${IOTGW_OTA_OPENSSL_CONF_VALUE}|g" \
        ${WORKDIR}/ota-updater.conf.in > ${D}${sysconfdir}/ota/updater.conf
    chmod 0640 ${D}${sysconfdir}/ota/updater.conf

    if ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', 'true', 'false', d)}; then
        install -m 0644 ${WORKDIR}/openssl-tpm2.cnf ${D}${sysconfdir}/ota/openssl-tpm2.cnf
        install -d ${D}${sysconfdir}/systemd/system/ota-updater.service.d
        install -m 0644 ${WORKDIR}/ota-updater-tpm.service.conf \
            ${D}${sysconfdir}/systemd/system/ota-updater.service.d/10-tpm.conf
    fi

    # Install tmpfiles.d for state directory
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/ota-updater.tmpfiles.conf ${D}${sysconfdir}/tmpfiles.d/ota-updater.conf
}

# -----------------------------------------------------------------------------
# Systemd integration (enable the timer, not the service directly)
# -----------------------------------------------------------------------------
SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "ota-updater.timer"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

# -----------------------------------------------------------------------------
# Package configuration
# -----------------------------------------------------------------------------
FILES:${PN} = " \
    ${sbindir}/ota-update-check \
    ${systemd_system_unitdir}/ota-updater.service \
    ${systemd_system_unitdir}/ota-updater.timer \
    ${sysconfdir}/ota/updater.conf \
    ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', '${sysconfdir}/ota/openssl-tpm2.cnf', '', d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', '${sysconfdir}/systemd/system/ota-updater.service.d/10-tpm.conf', '', d)} \
    ${sysconfdir}/tmpfiles.d/ota-updater.conf \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/ota/updater.conf \
    ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', '${sysconfdir}/ota/openssl-tpm2.cnf', '', d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', '${sysconfdir}/systemd/system/ota-updater.service.d/10-tpm.conf', '', d)} \
"

RDEPENDS:${PN} = " \
    bash \
    curl \
    jq \
    rauc \
    systemd \
    ca-certificates \
    iotgw-ota-user \
    ${@bb.utils.contains('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE', '1', 'tpm2-tss-engine tpm2-openssl', '', d)} \
"
