FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://containers.conf \
    file://storage.conf \
    file://90-iotgw-containers.conf \
    file://iotgw-containers.modules-load.conf \
    file://50-iotgw-podman-user.preset \
    file://podman-user-wait-network-online-noop.conf \
"

do_install:append() {
    install -d ${D}${sysconfdir}/containers
    install -m 0644 ${UNPACKDIR}/containers.conf ${D}${sysconfdir}/containers/containers.conf
    install -m 0644 ${UNPACKDIR}/storage.conf ${D}${sysconfdir}/containers/storage.conf

    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/90-iotgw-containers.conf ${D}${sysconfdir}/sysctl.d/90-iotgw-containers.conf

    # tun at boot: the kernel builds it as a module and the rootless network
    # helper (pasta) opens /dev/net/tun from an unprivileged user namespace,
    # which may not request a module load.
    install -d ${D}${nonarch_libdir}/modules-load.d
    install -m 0644 ${UNPACKDIR}/iotgw-containers.modules-load.conf \
        ${D}${nonarch_libdir}/modules-load.d/iotgw-containers.conf

    # Rootless podman API and timers are not started in user sessions (see the file).
    install -d ${D}${systemd_unitdir}/user-preset
    install -m 0644 ${UNPACKDIR}/50-iotgw-podman-user.preset ${D}${systemd_unitdir}/user-preset/

    # Every rootless Quadlet unit is ordered after podman's
    # podman-user-wait-network-online.service, which polls the SYSTEM
    # network-online.target from a user service until a 90 s timeout. Here
    # that target is a trivial sync point (wait-online is masked), so the
    # wait adds nothing; made a no-op for every user manager.
    install -d ${D}${systemd_user_unitdir}/podman-user-wait-network-online.service.d
    install -m 0644 ${UNPACKDIR}/podman-user-wait-network-online-noop.conf \
        ${D}${systemd_user_unitdir}/podman-user-wait-network-online.service.d/10-iotgw-noop.conf
}

FILES:${PN}:append = " \
    ${sysconfdir}/containers/containers.conf \
    ${sysconfdir}/containers/storage.conf \
    ${sysconfdir}/sysctl.d/90-iotgw-containers.conf \
    ${nonarch_libdir}/modules-load.d/iotgw-containers.conf \
    ${systemd_unitdir}/user-preset/50-iotgw-podman-user.preset \
    ${systemd_user_unitdir}/podman-user-wait-network-online.service.d/10-iotgw-noop.conf \
"

CONFFILES:${PN}:append = " \
    ${sysconfdir}/containers/containers.conf \
    ${sysconfdir}/containers/storage.conf \
    ${sysconfdir}/sysctl.d/90-iotgw-containers.conf \
"
