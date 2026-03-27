SUMMARY = "OpenThread Border Router Web UI"
DESCRIPTION = "Modern React + Fastify web interface for OTBR, replacing legacy otbr-web"
HOMEPAGE = "https://github.com/umair-as/otbr-webui"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=c0dee9c78b5e03982b9654da19cfa433"

SRC_URI = " \
    gitsm://github.com/umair-as/otbr-webui.git;branch=main;protocol=https \
    file://otbr-webui.service \
    file://otbr-webui.default \
"
SRCREV = "63af7a54e31b0c4b0dd416c7ec3e3e2165a7371b"
S = "${WORKDIR}/git"

DEPENDS = "nodejs-bin-native"

inherit systemd externalsrc

# Set in local.conf/local.yml when using a local checkout:
# EXTERNALSRC:pn-otbr-webui = "/path/to/otbr-webui"
# EXTERNALSRC_BUILD:pn-otbr-webui = "/path/to/otbr-webui"
EXTERNALSRC ?= ""
EXTERNALSRC_BUILD ?= "${WORKDIR}/build"

# Build: npm ci (full deps for build tools) -> npm run build -> prune to production
do_compile() {
    rm -rf ${B}
    install -d ${B}
    cp -a ${S}/. ${B}/
    rm -rf ${B}/node_modules ${B}/dist
    cd ${B}
    export HOME=${WORKDIR}
    npm ci --ignore-scripts --no-audit --fund=false
    npm run build
    # Remove devDependencies, keep only production runtime deps
    npm prune --omit=dev --no-audit --fund=false
}

# npm install requires registry access during compile.
do_compile[network] = "1"

# Install: dist/ + node_modules/ + package.json -> /usr/share/otbr-webui/
INSTALL_DIR = "${datadir}/otbr-webui"

do_install() {
    install -d ${D}${INSTALL_DIR}
    cp -r ${B}/dist ${D}${INSTALL_DIR}/
    cp -r ${B}/node_modules ${D}${INSTALL_DIR}/
    install -m 0644 ${B}/package.json ${D}${INSTALL_DIR}/

    # Systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/otbr-webui.service ${D}${systemd_system_unitdir}/

    # Environment file
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/otbr-webui.default ${D}${sysconfdir}/default/otbr-webui
}

FILES:${PN} = " \
    ${INSTALL_DIR} \
    ${systemd_system_unitdir}/otbr-webui.service \
    ${sysconfdir}/default/otbr-webui \
"
CONFFILES:${PN} = "${sysconfdir}/default/otbr-webui"

RDEPENDS:${PN} = "nodejs-bin"

SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "otbr-webui.service"

# Skip QA for bundled node_modules (prebuilt native addons, symlinks, etc.)
INSANE_SKIP:${PN} = "already-stripped file-rdeps"
