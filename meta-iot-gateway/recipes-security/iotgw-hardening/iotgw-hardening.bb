SUMMARY = "IoT Gateway Security Hardening"
DESCRIPTION = "Security hardening configurations based on Lynis audit recommendations"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://99-iotgw-hardening.conf \
    file://blacklist.conf \
    file://limits-hardening.conf \
    file://umask.sh \
    file://50-core-limits.conf \
    file://coredump.conf \
    file://tmp.mount.override \
    file://dev-shm.mount.override \
    file://service-hardening.conf \
    file://service-hardening-net.conf \
    file://sshd@.service \
    file://service-hardening-mosquitto.conf \
"

S = "${WORKDIR}"

do_install() {
    # Sysctl hardening (KRNL-6000)
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${WORKDIR}/99-iotgw-hardening.conf ${D}${sysconfdir}/sysctl.d/

    # Module blacklist (runtime prevention)
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/blacklist.conf ${D}${sysconfdir}/modprobe.d/iotgw-blacklist.conf

    # Core dump limits (KRNL-5820)
    install -d ${D}${sysconfdir}/security/limits.d
    install -m 0644 ${WORKDIR}/limits-hardening.conf ${D}${sysconfdir}/security/limits.d/

    # Systemd default limits for all services (also enforces core=0 for daemons)
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${WORKDIR}/50-core-limits.conf ${D}${sysconfdir}/systemd/system.conf.d/

    # Disable persistent core dumps for user processes (coredumpd)
    install -d ${D}${sysconfdir}/systemd/coredump.conf.d
    install -m 0644 ${WORKDIR}/coredump.conf ${D}${sysconfdir}/systemd/coredump.conf.d/iotgw.conf

    # Harden tmpfs mounts for /tmp and /dev/shm via drop-in units
    install -d ${D}${sysconfdir}/systemd/system/tmp.mount.d
    install -m 0644 ${WORKDIR}/tmp.mount.override ${D}${sysconfdir}/systemd/system/tmp.mount.d/override.conf
    install -d ${D}${sysconfdir}/systemd/system/dev-shm.mount.d
    install -m 0644 ${WORKDIR}/dev-shm.mount.override ${D}${sysconfdir}/systemd/system/dev-shm.mount.d/override.conf

    # Systemd service hardening drop-ins for network-facing services
    for unit in dnsmasq.service avahi-daemon.service; do
        install -d ${D}${sysconfdir}/systemd/system/${unit}.d
        install -m 0644 ${WORKDIR}/service-hardening.conf ${D}${sysconfdir}/systemd/system/${unit}.d/override.conf
    done
    for unit in NetworkManager.service wpa_supplicant.service; do
        install -d ${D}${sysconfdir}/systemd/system/${unit}.d
        install -m 0644 ${WORKDIR}/service-hardening-net.conf ${D}${sysconfdir}/systemd/system/${unit}.d/override.conf
    done

    install -d ${D}${sysconfdir}/systemd/system/mosquitto.service.d
    install -m 0644 ${WORKDIR}/service-hardening-mosquitto.conf ${D}${sysconfdir}/systemd/system/mosquitto.service.d/override.conf

    # Ship hardened sshd@ unit directly.
    install -d ${D}${sysconfdir}/systemd/system
    install -m 0644 ${WORKDIR}/sshd@.service ${D}${sysconfdir}/systemd/system/sshd@.service

    # Restrictive umask (AUTH-9328)
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${WORKDIR}/umask.sh ${D}${sysconfdir}/profile.d/
    # Note: login.defs hardening is applied via shadow_%.bbappend at package build time
}


FILES:${PN} = " \
    ${sysconfdir}/sysctl.d/99-iotgw-hardening.conf \
    ${sysconfdir}/modprobe.d/iotgw-blacklist.conf \
    ${sysconfdir}/security/limits.d/limits-hardening.conf \
    ${sysconfdir}/systemd/system.conf.d/50-core-limits.conf \
    ${sysconfdir}/systemd/coredump.conf.d/iotgw.conf \
    ${sysconfdir}/systemd/system/tmp.mount.d/override.conf \
    ${sysconfdir}/systemd/system/dev-shm.mount.d/override.conf \
    ${sysconfdir}/systemd/system/NetworkManager.service.d/override.conf \
    ${sysconfdir}/systemd/system/wpa_supplicant.service.d/override.conf \
    ${sysconfdir}/systemd/system/dnsmasq.service.d/override.conf \
    ${sysconfdir}/systemd/system/mosquitto.service.d/override.conf \
    ${sysconfdir}/systemd/system/avahi-daemon.service.d/override.conf \
    ${sysconfdir}/systemd/system/sshd@.service \
    ${sysconfdir}/profile.d/umask.sh \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/sysctl.d/99-iotgw-hardening.conf \
    ${sysconfdir}/modprobe.d/iotgw-blacklist.conf \
    ${sysconfdir}/security/limits.d/limits-hardening.conf \
    ${sysconfdir}/profile.d/umask.sh \
"
