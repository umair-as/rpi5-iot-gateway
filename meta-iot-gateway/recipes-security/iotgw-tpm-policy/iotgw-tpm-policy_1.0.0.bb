# SPDX-License-Identifier: MIT

SUMMARY = "IoT Gateway TPM device access policy"
DESCRIPTION = "Creates dedicated TPM user/group and enforces TPM device node ownership/permissions via udev."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit useradd

SRC_URI = "file://tpm-udev.rules"

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
    # Override upstream tpm-udev.rules to enforce IoTGW policy and avoid
    # user-resolution issues when 'tss' is not present.
    install -m 0644 ${WORKDIR}/tpm-udev.rules ${D}${sysconfdir}/udev/rules.d/tpm-udev.rules
}

FILES:${PN} = " \
    ${sysconfdir}/udev/rules.d/tpm-udev.rules \
"

RDEPENDS:${PN} = "udev"

