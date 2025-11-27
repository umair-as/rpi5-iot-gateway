SUMMARY = "OpenThread Border Router for Raspberry Pi 5"
DESCRIPTION = "OpenThread Border Router (OTBR) - POSIX implementation for RPi5"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=87109e44b2fda96a8991f27684a7349c"

PATCHTOOL = "git"

SRC_URI += " \
    file://otbr-agent.service \
    file://otbr-web.service \
    file://otbr-ipset-init.sh \
"

S = "${WORKDIR}/git"
# Ship systemd units and web assets
FILES:${PN} += "${systemd_system_unitdir} ${datadir}/otbr-web"

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
    iptables \
    libnftnl \
    nftables \
    protobuf \
    protobuf-c \
    dhcpcd \
"

inherit cmake systemd

# Use upstream OpenThread Border Router
SRC_URI += "gitsm://github.com/openthread/ot-br-posix.git;branch=main;protocol=https"

# Use a recent stable commit or tag
SRCREV = "45c847a6b47cef00c9e3d46786127ef87475437d"

# OTBR Configuration for Raspberry Pi 5 (host, with Web UI)
# Keep flags minimal and rely on upstream defaults where possible.
IOTGW_OT_THREAD_VERSION ?= "1.3"

EXTRA_OECMAKE = " \
    -GNinja \
    -DBUILD_TESTING=OFF \
    -DOTBR_WEB=ON \
    -DOTBR_DBUS=ON \
    -DOTBR_MDNS=avahi \
    -DOTBR_BORDER_ROUTING=ON \
    -DOTBR_BACKBONE_ROUTER=ON \
    -DOTBR_INFRA_IF_NAME=wlan0 \
    -DOTBR_RADIO_URL=spinel+hdlc+uart:///dev/ttyACM0 \
    -DOT_THREAD_VERSION=${IOTGW_OT_THREAD_VERSION} \
    -DCMAKE_CXX_STANDARD=17 \
"

# Web UI requires Node.js (native) and network access during compile (npm)
DEPENDS += " nodejs-bin-native"
do_compile[network] = "1"

# Enable and configure systemd services
SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "otbr-agent.service otbr-web.service"

# Install fixed systemd service files
do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/otbr-agent.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/otbr-web.service ${D}${systemd_system_unitdir}/

    # Provide default env for web to avoid warnings
    install -d ${D}${sysconfdir}/default
    echo 'OTBR_WEB_OPTS=""' > ${D}${sysconfdir}/default/otbr-web

    # Install ipset init helper
    install -d ${D}${libexecdir}/otbr
    install -m 0755 ${WORKDIR}/otbr-ipset-init.sh ${D}${libexecdir}/otbr/otbr-ipset-init
}

FILES:${PN} += "${sysconfdir}/default/otbr-web"
CONFFILES:${PN} += "${sysconfdir}/default/otbr-web"
FILES:${PN} += "${libexecdir}/otbr/otbr-ipset-init"
