# SPDX-License-Identifier: MIT

SUMMARY = "IoT Gateway TPM device access policy"
DESCRIPTION = "Creates dedicated TPM user/group and enforces TPM device node ownership/permissions via udev."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit useradd

SRC_URI = " \
    file://tpm-udev.rules \
    file://iotgw-tpm-env.sh \
    file://50-iotgw-tpm.conf \
    file://10-iotgw-tpm-defaults.conf \
"

S = "${WORKDIR}"

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system iotgwtpm"
USERADD_PARAM:${PN} = " \
    --system \
    --home-dir /nonexistent \
    --no-create-home \
    --shell /sbin/nologin \
    --gid iotgwtpm \
    --comment 'IoT Gateway TPM service user' \
    iotgwtpm \
"

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -d ${D}${sysconfdir}/profile.d
    install -d ${D}${sysconfdir}/environment.d
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    # Override upstream tpm-udev.rules to enforce IoTGW policy and avoid
    # user-resolution issues when 'tss' is not present.
    install -m 0644 ${WORKDIR}/tpm-udev.rules ${D}${sysconfdir}/udev/rules.d/tpm-udev.rules
    install -m 0644 ${WORKDIR}/iotgw-tpm-env.sh ${D}${sysconfdir}/profile.d/iotgw-tpm-env.sh
    install -m 0644 ${WORKDIR}/50-iotgw-tpm.conf ${D}${sysconfdir}/environment.d/50-iotgw-tpm.conf
    install -m 0644 ${WORKDIR}/10-iotgw-tpm-defaults.conf ${D}${sysconfdir}/systemd/system.conf.d/10-iotgw-tpm-defaults.conf
}

FILES:${PN} = " \
    ${sysconfdir}/udev/rules.d/tpm-udev.rules \
    ${sysconfdir}/profile.d/iotgw-tpm-env.sh \
    ${sysconfdir}/environment.d/50-iotgw-tpm.conf \
    ${sysconfdir}/systemd/system.conf.d/10-iotgw-tpm-defaults.conf \
"

RDEPENDS:${PN} = "udev"
