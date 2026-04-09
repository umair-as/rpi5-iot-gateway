SUMMARY = "IoT GW dev encrypted store (LUKS2 + TPM token)"
DESCRIPTION = "Creates and mounts a loopback LUKS2 encrypted store under /data for TPM/cryptsetup integration testing."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-encrypted-store-setup.sh \
    file://iotgw-encrypted-store-setup.service \
    file://data-encstore.mount \
    file://iotgw-encrypted-store.tmpfiles.conf \
    file://iotgw-encrypted-store.default \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-encrypted-store-setup.service data-encstore.mount"
# Enable at image build time so boot graph sees units on read-only rootfs setups
# with /etc overlay, where runtime `systemctl enable` can be non-deterministic.
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/iotgw-encrypted-store-setup.sh ${D}${sbindir}/iotgw-encrypted-store-setup

    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/iotgw-encrypted-store.default ${D}${sysconfdir}/default/iotgw-encrypted-store

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-encrypted-store-setup.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/data-encstore.mount ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/iotgw-encrypted-store.tmpfiles.conf ${D}${sysconfdir}/tmpfiles.d/iotgw-encrypted-store.conf
}

FILES:${PN} += " \
    ${sbindir}/iotgw-encrypted-store-setup \
    ${sysconfdir}/default/iotgw-encrypted-store \
    ${systemd_system_unitdir}/iotgw-encrypted-store-setup.service \
    ${systemd_system_unitdir}/data-encstore.mount \
    ${sysconfdir}/tmpfiles.d/iotgw-encrypted-store.conf \
"

RDEPENDS:${PN} += " \
    bash \
    cryptsetup \
    e2fsprogs-mke2fs \
    e2fsprogs-tune2fs \
    util-linux \
    systemd \
"
