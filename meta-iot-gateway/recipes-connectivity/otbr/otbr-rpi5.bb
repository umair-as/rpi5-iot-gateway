SUMMARY = "OpenThread Border Router for Raspberry Pi 5"
DESCRIPTION = "OpenThread Border Router (OTBR) - POSIX implementation for RPi5"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=87109e44b2fda96a8991f27684a7349c"

PATCHTOOL = "git"

SRC_URI += " \
    file://otbr-agent.service \
    file://otbr-ipset-init.sh \
    file://otbr-agent.default \
    file://otbr-agent.conf \
    file://otbr-socket-dir.patch \
    file://otbr-skip-npm-frontend.patch \
    file://otbr-tmpfiles.conf \
    file://otbr-rcp.rules \
    file://dbus-wrapper-otbr.sh \
    file://otbr-config-paths.patch \
"

S = "${WORKDIR}/git"
# Ship systemd units
FILES:${PN} += "${systemd_system_unitdir} ${sysconfdir}/udev/rules.d/99-otbr-rcp.rules"

DEPENDS += " \
    jsoncpp \
    avahi \
    boost \
    pkgconfig-native \
    mdns \
    libnetfilter-queue \
    ipset \
    libnftnl \
    nftables \
    protobuf-c \
    protobuf \
    protobuf-native \
"

RDEPENDS:${PN} += " \
    jsoncpp \
    avahi-daemon \
    avahi-utils \
    radvd \
    libnetfilter-queue \
    ipset \
    libnftnl \
    nftables \
    protobuf \
    protobuf-c \
    bash \
    otbr-webui \
"

inherit cmake systemd useradd

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system otbr"
USERADD_PARAM:${PN} = "--system --home-dir /var/lib/otbr --shell /sbin/nologin --comment 'User for otbr' --gid otbr --groups dialout otbr"

# Use upstream OpenThread Border Router
SRC_URI += "gitsm://github.com/openthread/ot-br-posix.git;branch=main;protocol=https"

# Use a recent stable commit or tag
SRCREV = "02225a5ba6f984a9ade970a799bc47e44837c2a3"

# OTBR Configuration for Raspberry Pi 5 (agent only, web UI via otbr-webui)
# Keep flags minimal and rely on upstream defaults where possible.
IOTGW_OT_THREAD_VERSION ?= "1.4"

EXTRA_OECMAKE = " \
    -GNinja \
    -DBUILD_TESTING=OFF \
    -DOTBR_VENDOR_NAME=IoTGateway \
    -DOTBR_PRODUCT_NAME=EdgeGW \
    -DOTBR_WEB=OFF \
    -DOTBR_REST=ON \
    -DOTBR_DBUS=ON \
    -DOTBR_MDNS=avahi \
    -DOTBR_BORDER_ROUTING=ON \
    -DOTBR_BACKBONE_ROUTER=ON \
    -DOTBR_INFRA_IF_NAME=wlan0 \
    -DOTBR_RADIO_URL=spinel+hdlc+uart:///dev/ttyACM0 \
    -DOT_THREAD_VERSION=${IOTGW_OT_THREAD_VERSION} \
    -DCMAKE_CXX_STANDARD=17 \
"

# Enable telemetry and link metrics for richer D-Bus/dashboard data.
EXTRA_OECMAKE:append = " -DOTBR_TELEMETRY_DATA_API=ON -DOTBR_LINK_METRICS_TELEMETRY=ON -DOTBR_FEATURE_FLAGS=ON"

# Enable and configure systemd services
SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "otbr-agent.service"

# Install fixed systemd service files
do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/otbr-agent.service ${D}${systemd_system_unitdir}/

    # Provide default env for agent
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/otbr-agent.default ${D}${sysconfdir}/default/otbr-agent

    # Install ipset init helper
    install -d ${D}${libexecdir}/otbr
    install -m 0755 ${WORKDIR}/otbr-ipset-init.sh ${D}${libexecdir}/otbr/otbr-ipset-init

    # tmpfiles rule to allow otbr to create /run sockets
    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/otbr-tmpfiles.conf ${D}${libdir}/tmpfiles.d/otbr.conf

    # Ensure DBus policy allows otbr user
    install -d ${D}${sysconfdir}/dbus-1/system.d
    install -m 0644 ${WORKDIR}/otbr-agent.conf ${D}${sysconfdir}/dbus-1/system.d/otbr-agent.conf

    # Udev rule for RCP device access
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/otbr-rcp.rules ${D}${sysconfdir}/udev/rules.d/99-otbr-rcp.rules

    # Install DBus wrapper helper (debug/testing)
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/dbus-wrapper-otbr.sh ${D}${sbindir}/dbus-wrapper-otbr.sh
}

FILES:${PN} += "${sysconfdir}/default/otbr-agent"
CONFFILES:${PN} += "${sysconfdir}/default/otbr-agent"
FILES:${PN} += "${libexecdir}/otbr/otbr-ipset-init"
FILES:${PN} += "${libdir}/tmpfiles.d/otbr.conf"
