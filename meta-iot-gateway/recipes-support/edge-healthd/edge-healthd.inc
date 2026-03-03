# SPDX-License-Identifier: MIT
#
# edge-healthd: Edge device health monitoring daemon
#

SUMMARY = "Edge device health monitoring daemon"
DESCRIPTION = "Continuously monitors device health (boot, services, resources, \
time sync, updates) and writes structured JSON status for fleet management integration."
HOMEPAGE = "https://github.com/umair-as/edge-healthd"
RECIPE_MAINTAINER = "Umair A.S <umair-uas@users.noreply.github.com>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=291c1ca2c1503b0e42022cd4bff87df5"

BRANCH ?= "main"
SRC_URI = "git://github.com/umair-as/edge-healthd.git;branch=${BRANCH};protocol=https"
S = "${WORKDIR}/git"

# Platform-specific configuration and tmpfiles
SRC_URI += " \
    file://healthd.conf \
    file://edge-healthd.tmpfiles.conf \
"

inherit cmake systemd useradd pkgconfig externalsrc
EXTERNALSRC ?= ""
EXTERNALSRC_BUILD ?= "${WORKDIR}/build"
PACKAGECONFIG ??= "systemd"
PACKAGECONFIG[systemd] = "-DEDGE_HAS_SYSTEMD=ON,,systemd"
PACKAGECONFIG[tests] = "-DEDGE_BUILD_TESTS=ON,-DEDGE_BUILD_TESTS=OFF"
PACKAGECONFIG[web-ui] = "-DEDGE_WEB_UI=ON,-DEDGE_WEB_UI=OFF,go-native"
DEPENDS += " \
    systemd \
    nlohmann-json \
    json-schema-validator \
    sdbus-c++ \
    sdbus-c++-tools-native \
    libmnl \
"

RDEPENDS:${PN} += " \
    libmnl \
    libnl \
    libnl-genl \
    libnl-route \
    systemd \
"

# -----------------------------------------------------------------------------
# User/Group creation
# -----------------------------------------------------------------------------
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r edgehealth"
USERADD_PARAM:${PN} = "\
    --system \
    --home /nonexistent \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --gid edgehealth \
    --comment 'Edge Health Daemon' \
    edgehealth \
"

# -----------------------------------------------------------------------------
# CMake configuration
# -----------------------------------------------------------------------------
EXTRA_OECMAKE = " \
    -DEDGE_BUILD_TESTS=OFF \
    -DEDGE_ENABLE_SANITIZERS=OFF \
    -DEDGE_ENABLE_LTO=ON \
    -DEDGE_WEB_UI=OFF \
    -DEDGE_FETCH_SDBUSCPP=OFF \
    -DEDGE_STATIC_LINK=OFF \
"

# -----------------------------------------------------------------------------
# Installation
# -----------------------------------------------------------------------------
do_install:append() {
    # Systemd service is installed by CMake, but ensure correct location
    install -d ${D}${systemd_system_unitdir}
    if [ -f ${D}${prefix}/lib/systemd/system/edge-healthd.service ] && \
       [ "${systemd_system_unitdir}" != "${prefix}/lib/systemd/system" ]; then
        mv ${D}${prefix}/lib/systemd/system/edge-healthd.service ${D}${systemd_system_unitdir}/
        rmdir --ignore-fail-on-non-empty ${D}${prefix}/lib/systemd/system || true
        rmdir --ignore-fail-on-non-empty ${D}${prefix}/lib/systemd || true
    fi

    # Install platform-specific config (overrides upstream example)
    install -d ${D}${sysconfdir}/edge
    install -m 0644 ${WORKDIR}/healthd.conf ${D}${sysconfdir}/edge/healthd.conf

    # Remove upstream example config if installed
    rm -f ${D}${sysconfdir}/edge/healthd.conf.example

    # Install tmpfiles.d configuration for state directory
    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/edge-healthd.tmpfiles.conf ${D}${sysconfdir}/tmpfiles.d/edge-healthd.conf
}

# -----------------------------------------------------------------------------
# Systemd integration
# -----------------------------------------------------------------------------
SYSTEMD_SERVICE:${PN} = "edge-healthd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

# -----------------------------------------------------------------------------
# Package configuration
# -----------------------------------------------------------------------------
FILES:${PN} += " \
    ${systemd_system_unitdir}/edge-healthd.service \
    ${sysconfdir}/edge/healthd.conf \
    ${sysconfdir}/tmpfiles.d/edge-healthd.conf \
"

CONFFILES:${PN} += " \
    ${sysconfdir}/edge/healthd.conf \
"
