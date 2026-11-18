SUMMARY = "Attract-mode maths and physics demo for an HDMI screen"
DESCRIPTION = "Nine raylib scenes (spring and phasor, square-wave harmonics with \
audio, Fourier epicycles, standing waves, FFT spectrogram, double pendulum, \
Lissajous figures, two-source interference, Lorenz attractor). \
One codebase, two display paths chosen at build time: a Wayland client for \
Weston, or DRM/KMS without a compositor."
HOMEPAGE = "https://github.com/umair-as/hdmi-wave-demo"

# The demo is MIT. raylib 5.5 (zlib) is compiled from source and linked
# statically into the one binary, so its licence ships too. raylib bundles
# GLFW (zlib), miniaudio and the stb headers (public domain / MIT-0).
LICENSE = "MIT & Zlib"
LIC_FILES_CHKSUM = "file://LICENSE;md5=13410be1caae14890d1c1a981fee4482 \
                    file://${RAYLIB_SRC}/LICENSE;md5=e5c04526673eda16f837e05cb1177261"

RAYLIB_PV = "5.5"

SRC_URI = " \
    ${HDMI_WAVE_DEMO_GIT};branch=main \
    git://github.com/raysan5/raylib.git;protocol=https;nobranch=1;name=raylib;destsuffix=raylib-${RAYLIB_PV} \
    file://hdmi-wave-demo.service \
    file://hdmi-wave-demo-kiosk \
    file://weston-autolaunch.ini \
"
# Override HDMI_WAVE_DEMO_GIT with a local clone (git:///path;protocol=file) to
# develop against unpushed work; the fetch is still the pinned commit.
HDMI_WAVE_DEMO_GIT ?= "git://github.com/umair-as/hdmi-wave-demo.git;protocol=https"
SRCREV = "47ee1377670300319dc8cd7408e159c7e264c335"
# raylib 5.5 by git, not the GitHub release archive (oe-core QA src-uri-bad):
# the commit of the 5.5 tag.
SRCREV_raylib = "c1ab645ca298a2801097931d1079b10ff7eb9df8"
SRCREV_FORMAT = "default_raylib"

PV = "0.2.0+git"

inherit cmake pkgconfig systemd

# Exactly one display path. wayland: raylib PLATFORM_DESKTOP with the bundled
# GLFW, Wayland backend only, GLES 3.0 (Mesa v3d). drm: raylib PLATFORM_DRM,
# GBM/EGL/GLES 2.0 straight to KMS.
#
# GLFW dlopen()s libwayland-client/-cursor/-egl, libxkbcommon, libEGL and
# libGLESv2, so the shlib scanner sees none of them: they are listed as
# RDEPENDS here. virtual/libgl is a link-time dependency only (raylib's
# desktop platform names libGL; --as-needed drops it from the binary).
PACKAGECONFIG ??= "wayland"
PACKAGECONFIG[wayland] = "-DHWD_PLATFORM=wayland -DHWD_DESKTOP_BACKEND=GLFW -DHWD_GLFW_X11=OFF -DHWD_GLES=ON,,wayland wayland-native wayland-protocols libxkbcommon virtual/egl virtual/libgles2 virtual/libgl,wayland libxkbcommon libegl-mesa libgles2-mesa"
PACKAGECONFIG[drm] = "-DHWD_PLATFORM=drm,,libdrm virtual/libgbm virtual/egl virtual/libgles2"

python () {
    pc = (d.getVar('PACKAGECONFIG') or '').split()
    chosen = [p for p in ('wayland', 'drm') if p in pc]
    if len(chosen) != 1:
        raise bb.parse.SkipRecipe("hdmi-wave-demo: PACKAGECONFIG must contain exactly one of "
                                  "'wayland' or 'drm' (has: %s)" % (' '.join(chosen) or 'neither'))
}

# raylib is built from the second SRC_URI entry: no network after do_fetch.
# externalsrc drops remote SRC_URI entries, so an EXTERNALSRC build points
# RAYLIB_SRC at an extracted raylib 5.5 tree (also used for its licence file).
RAYLIB_SRC ?= "${UNPACKDIR}/raylib-${RAYLIB_PV}"
# raylib is a second source tree (UNPACKDIR/raylib-*), outside the S/B paths
# the default prefix map covers; map it too, or its build paths end up in
# the debug info (QA buildpaths).
DEBUG_PREFIX_MAP:append = " -ffile-prefix-map=${RAYLIB_SRC}=${TARGET_DBGSRC_DIR}/raylib-${RAYLIB_PV}"
EXTRA_OECMAKE += " \
    -DFETCHCONTENT_SOURCE_DIR_RAYLIB=${RAYLIB_SRC} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DHWD_DEV_ASSETS=OFF \
    -DBUILD_TESTING=OFF \
"

# miniaudio (inside raylib) dlopen()s the ALSA library for sound and capture.
RRECOMMENDS:${PN} += "alsa-lib"

# The desktop image's boot default on HDMI: enabled. The DX-M1 demo launcher
# is the other fullscreen client, and the units conflict.
SYSTEMD_SERVICE:${PN} = "hdmi-wave-demo.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}/${BPN} ${D}${datadir}/${BPN}
    sed -e 's|@BINDIR@|${bindir}|g' ${UNPACKDIR}/hdmi-wave-demo.service \
        > ${D}${systemd_system_unitdir}/hdmi-wave-demo.service
    chmod 0644 ${D}${systemd_system_unitdir}/hdmi-wave-demo.service
    sed -e 's|@BINDIR@|${bindir}|g' ${UNPACKDIR}/hdmi-wave-demo-kiosk \
        > ${D}${libexecdir}/${BPN}/kiosk
    chmod 0755 ${D}${libexecdir}/${BPN}/kiosk
    # The SVGs (scene 3 defaults) are installed by CMake to ${datadir}/${BPN}/assets.
    # Reference snippet only: weston-init owns ${sysconfdir}/xdg/weston/weston.ini.
    sed -e 's|@LIBEXECDIR@|${libexecdir}|g' ${UNPACKDIR}/weston-autolaunch.ini \
        > ${D}${datadir}/${BPN}/weston-autolaunch.ini
    chmod 0644 ${D}${datadir}/${BPN}/weston-autolaunch.ini
}

FILES:${PN} += " \
    ${datadir}/${BPN} \
    ${libexecdir}/${BPN} \
"
