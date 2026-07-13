SUMMARY = "Persistent machine-id setup for immutable rootfs deployments"
DESCRIPTION = "Ensures machine-id is persisted under /data and bind-mounted to /etc/machine-id before regular services."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://iotgw-machine-id.sh \
    file://iotgw-machine-id.service \
"

inherit systemd

S = "${UNPACKDIR}"

SYSTEMD_SERVICE:${PN} = "iotgw-machine-id.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/iotgw-machine-id.sh ${D}${sbindir}/iotgw-machine-id

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-machine-id.service ${D}${systemd_system_unitdir}/

    # Mask systemd's machine-id commit unit: it exists to persist a
    # TRANSIENT id (tmpfs bind) to disk and drop the bind. This image's
    # bind-mount is permanent by design (persistent id under /data), so
    # the unit's job never applies — and when its
    # ConditionPathIsMountPoint=/etc/machine-id races true against our
    # bind, it fails with "not on a temporary file system" and degrades
    # the boot.
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-machine-id-commit.service
}

FILES:${PN} += " \
    ${sbindir}/iotgw-machine-id \
    ${systemd_system_unitdir}/iotgw-machine-id.service \
    ${sysconfdir}/systemd/system/systemd-machine-id-commit.service \
"

RDEPENDS:${PN} += "bash util-linux systemd"
