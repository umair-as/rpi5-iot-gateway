SUMMARY = "Systemd PID1 hardware watchdog configuration"
DESCRIPTION = "Installs a systemd.conf vendor drop-in enabling \
RuntimeWatchdogSec/ShutdownWatchdogSec when explicitly enabled. Shipped under \
${nonarch_libdir}/systemd (not ${sysconfdir}): on this image /etc is an overlay \
whose upperdir lives on /data, so a runtime-written /etc drop-in is invisible \
until /data mounts; the vendor dir is read at PID1 start regardless, and leaves \
/etc free for operator overrides."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://60-iotgw-watchdog.conf.in"

S = "${UNPACKDIR}"
# @IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC@ and @IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC@
# are substituted from MACHINE-specific variables at install time.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${nonarch_libdir}/systemd/system.conf.d
    sed -e "s|@IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC@|${IOTGW_SYSTEMD_RUNTIME_WATCHDOG_SEC}|g" \
        -e "s|@IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC@|${IOTGW_SYSTEMD_SHUTDOWN_WATCHDOG_SEC}|g" \
        ${UNPACKDIR}/60-iotgw-watchdog.conf.in \
        > ${D}${nonarch_libdir}/systemd/system.conf.d/60-iotgw-watchdog.conf
    chmod 0644 ${D}${nonarch_libdir}/systemd/system.conf.d/60-iotgw-watchdog.conf
}

FILES:${PN} = "${nonarch_libdir}/systemd/system.conf.d/60-iotgw-watchdog.conf"
