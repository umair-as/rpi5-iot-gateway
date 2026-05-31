SUMMARY = "IoT Gateway dynamic login banner generator"
DESCRIPTION = "Renders /etc/issue (TTY pre-login), /etc/issue.net (SSH \
pre-login), and /etc/motd (TTY post-login via /bin/login MOTD_FILE) with \
runtime system information -- distro identity, RAUC slot + boot status, \
kernel, default-route source IP and other global-scope addresses, OTA \
state. Includes a NetworkManager dispatcher script that refreshes all \
three on interface state and DHCP lease changes so IP fields do not go \
stale across the boot lifetime."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-banner.sh \
    file://iotgw-banner.service \
    file://50-iotgw-banner \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "iotgw-banner.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # Generator script with build-time identity baked in.
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/iotgw-banner.sh ${D}${bindir}/iotgw-banner.sh
    sed -i -e "s|@DISTRO_NAME@|${DISTRO_NAME}|g" \
           -e "s|@DISTRO_VERSION@|${DISTRO_VERSION}|g" \
           -e "s|@MACHINE@|${MACHINE}|g" \
           ${D}${bindir}/iotgw-banner.sh

    # Boot oneshot: writes the initial /etc/issue + /etc/issue.net.
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/iotgw-banner.service ${D}${systemd_system_unitdir}/iotgw-banner.service

    # NetworkManager dispatcher: regenerates banners when interface state
    # or DHCP lease changes, so the IP fields stay current.
    install -d ${D}${sysconfdir}/NetworkManager/dispatcher.d
    install -m 0755 ${WORKDIR}/50-iotgw-banner ${D}${sysconfdir}/NetworkManager/dispatcher.d/50-iotgw-banner
}

FILES:${PN} += " \
    ${bindir}/iotgw-banner.sh \
    ${systemd_system_unitdir}/iotgw-banner.service \
    ${sysconfdir}/NetworkManager/dispatcher.d/50-iotgw-banner \
"

# networkmanager: the dispatcher script lives in NM's dispatcher.d/ and the
# IP-freshness contract depends on NM firing dispatch events.
RDEPENDS:${PN} = "bash iproute2 rauc systemd networkmanager"
