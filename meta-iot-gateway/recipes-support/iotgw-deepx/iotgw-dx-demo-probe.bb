SUMMARY = "DX-M1 confined launcher and acceptance inference probe"
DESCRIPTION = "The DX-M1 launcher binary, its unprivileged account and the \
acceptance inference probe unit. No display stack, so every DX-M1 image takes \
it and the acceptance check runs inference in iotgw_dxdemo_t on a headless \
image too, with a model pushed at run time (scripts/deepx/dxm1-push-model.sh)."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# A recipe of its own, not a package of iotgw-dx-demo: BitBake resolves the
# runtime dependencies of every package a recipe builds, so a headless image
# taking a probe package from that recipe would still need weston-init.
SRC_URI = " \
    file://iotgw-dx-probe.service \
    file://iotgw-dx-demo \
"

S = "${UNPACKDIR}"

inherit useradd

# Supplementary group dxrt (iotgw-deepx-runtime) is created by another recipe,
# so membership is declared through IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS (distro),
# not --groups here.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system dxdemo"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /var/cache/dxdemo \
                       --shell /sbin/nologin --gid dxdemo dxdemo"

RDEPENDS:${PN} = "iotgw-deepx-runtime"

# iotgw-dx-probe.service is a static unit with no [Install] section (started by
# the acceptance check), so it is shipped as a plain file, not through the
# systemd class.
do_install() {
    install -d ${D}${systemd_system_unitdir} ${D}${libexecdir}
    install -m 0644 ${UNPACKDIR}/iotgw-dx-probe.service ${D}${systemd_system_unitdir}/
    install -m 0755 ${UNPACKDIR}/iotgw-dx-demo ${D}${libexecdir}/
    # Shipped rather than created by CacheDirectory= at runtime: the parent
    # /var/cache is var_t, which init_t may not write under enforcing (denied
    # without an AVC); systemd then only adjusts ownership and mode.
    install -d ${D}${localstatedir}/cache/dxdemo
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/iotgw-dx-probe.service \
    ${libexecdir}/iotgw-dx-demo \
    ${localstatedir}/cache/dxdemo \
"

pkg_postinst:${PN}() {
    chown dxdemo:dxdemo $D${localstatedir}/cache/dxdemo || true
}

COMPATIBLE_MACHINE = "raspberrypi5"
