SUMMARY = "Persist journald and audit logs on /data for read-only rootfs deployments"
DESCRIPTION = "Bind-mounts /data/log/{journal,audit} onto the volatile /var/volatile/log/{journal,audit} \
via systemd .mount units so the must-persist logs survive reboot once /var is no longer overlaid. \
An early oneshot prepares the backing dirs and mountpoints before journald flush; the binds are \
pulled by Wants= drop-ins on systemd-journal-flush and auditd."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-log-persist-prep.sh \
    file://iotgw-log-persist-prep.service \
    file://var-volatile-log-journal.mount \
    file://var-volatile-log-audit.mount \
    file://10-iotgw-journal-flush.conf \
    file://10-iotgw-auditd.conf \
"

inherit systemd

S = "${UNPACKDIR}"

# The prep oneshot runs early (WantedBy=sysinit.target) to create the backing
# dirs + mountpoints before the binds. The .mount units carry no [Install]: they
# are pulled + ordered by Wants=/After= drop-ins on their consumers
# (systemd-journal-flush and auditd) — RequiresMountsFor= via the /var/log
# symlink orders but does not reliably activate the bind at boot.
SYSTEMD_SERVICE:${PN} = "iotgw-log-persist-prep.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/iotgw-log-persist-prep.sh ${D}${sbindir}/iotgw-log-persist-prep

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iotgw-log-persist-prep.service ${D}${systemd_system_unitdir}/iotgw-log-persist-prep.service
    install -m 0644 ${UNPACKDIR}/var-volatile-log-journal.mount ${D}${systemd_system_unitdir}/var-volatile-log-journal.mount
    install -m 0644 ${UNPACKDIR}/var-volatile-log-audit.mount ${D}${systemd_system_unitdir}/var-volatile-log-audit.mount

    install -d ${D}${systemd_system_unitdir}/systemd-journal-flush.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-journal-flush.conf \
        ${D}${systemd_system_unitdir}/systemd-journal-flush.service.d/10-iotgw-log-persist.conf

    install -d ${D}${systemd_system_unitdir}/auditd.service.d
    install -m 0644 ${UNPACKDIR}/10-iotgw-auditd.conf \
        ${D}${systemd_system_unitdir}/auditd.service.d/10-iotgw-log-persist.conf
}

FILES:${PN} += " \
    ${sbindir}/iotgw-log-persist-prep \
    ${systemd_system_unitdir}/iotgw-log-persist-prep.service \
    ${systemd_system_unitdir}/var-volatile-log-journal.mount \
    ${systemd_system_unitdir}/var-volatile-log-audit.mount \
    ${systemd_system_unitdir}/systemd-journal-flush.service.d/10-iotgw-log-persist.conf \
    ${systemd_system_unitdir}/auditd.service.d/10-iotgw-log-persist.conf \
"

RDEPENDS:${PN} += "util-linux systemd coreutils"
