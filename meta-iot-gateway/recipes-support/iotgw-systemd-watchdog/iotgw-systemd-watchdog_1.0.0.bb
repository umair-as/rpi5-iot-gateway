SUMMARY = "Systemd PID1 hardware watchdog configuration"
DESCRIPTION = "Installs systemd.conf drop-in to enable RuntimeWatchdogSec/ShutdownWatchdogSec when explicitly enabled."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://60-iotgw-watchdog.conf.in"

S = "${WORKDIR}"
# @IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC@ and @IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC@
# are substituted from MACHINE-specific variables at install time.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    sed -e "s|@IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC@|${IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC}|g" \
        -e "s|@IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC@|${IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC}|g" \
        ${WORKDIR}/60-iotgw-watchdog.conf.in \
        > ${D}${sysconfdir}/systemd/system.conf.d/60-iotgw-watchdog.conf
    chmod 0644 ${D}${sysconfdir}/systemd/system.conf.d/60-iotgw-watchdog.conf
}

FILES:${PN} = "${sysconfdir}/systemd/system.conf.d/60-iotgw-watchdog.conf"
