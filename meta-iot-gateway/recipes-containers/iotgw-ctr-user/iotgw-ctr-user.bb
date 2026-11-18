SUMMARY = "Rootless container principal (iotgw-ctr): account, home, linger, Quadlet directory"
DESCRIPTION = "The one account that runs containers on the gateway. A non-login \
system user whose user manager is started at boot by systemd-logind (linger) \
and runs rootless podman from Quadlet units in /etc/containers/systemd/users/<uid>. \
Its home holds the container store (~/.local/share/containers) and lives on \
/data through the /home bind, so images survive OTA slot swaps. Shipped on \
every image; the Quadlet directory is empty until a workload is added."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit useradd

PACKAGE_ARCH = "${MACHINE_ARCH}"

IOTGW_CTR_USER = "iotgw-ctr"
# Numeric id of the principal. It names the Quadlet directory
# (/etc/containers/systemd/users/<uid>), so it must equal the entry in the
# static id tables that useradd-staticids injects into USERADD_PARAM; the
# anonymous function below fails the parse when the two disagree.
IOTGW_CTR_UID ?= "968"
IOTGW_CTR_HOME = "/home/${IOTGW_CTR_USER}"

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system ${IOTGW_CTR_USER}"
# uid/gid come from the static id tables (useradd-staticids rewrites the
# command with --uid/--gid). The home is created below so it is packaged and
# owned, not by useradd: the pre-init seeds /data/home from the image's /home
# entries, and a home that only a tmpfiles rule would create does not exist on
# the first boot. No supplementary groups: a group another recipe creates may
# not exist when this useradd runs, and a failed --groups loses the whole
# account (recipe-conventions: IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS instead).
USERADD_PARAM:${PN} = " \
    --system \
    --gid ${IOTGW_CTR_USER} \
    --home-dir ${IOTGW_CTR_HOME} \
    --no-create-home \
    --shell /sbin/nologin \
    --comment 'Rootless container principal' \
    ${IOTGW_CTR_USER} \
"

python () {
    import re
    user = d.getVar('IOTGW_CTR_USER')
    want = d.getVar('IOTGW_CTR_UID')
    found = None
    for table in (d.getVar('USERADD_UID_TABLES') or '').split():
        path = bb.utils.which(d.getVar('BBPATH'), table)
        if not path:
            continue
        with open(path) as f:
            for line in f:
                m = re.match(r'^%s:[^:]*:(\d+):' % re.escape(user), line)
                if m:
                    found = m.group(1)
    if found is None:
        bb.fatal("%s: no entry for %s in USERADD_UID_TABLES (%s)" % (d.getVar('PN'), user, d.getVar('USERADD_UID_TABLES')))
    if found != want:
        bb.fatal("%s: IOTGW_CTR_UID is %s but the static id table assigns %s to %s" % (d.getVar('PN'), want, found, user))
}

do_install() {
    # Home and the container store skeleton. storage/tmp is where podman stages
    # image layers (containers.conf image_copy_tmp_dir = "storage"); podman
    # creates the store but not that directory, and its default (/var/tmp) is
    # a tmpfs here. Everything 0700: the store maps container ids onto the
    # principal's subordinate range, nothing else reads it.
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.local
    # podman keeps state in ~/.config and ~/.cache, but its domain may not add
    # entries to the home directory itself.
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.config
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.cache
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.local/share
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.local/share/containers
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.local/share/containers/storage
    install -d -m 0700 ${D}${IOTGW_CTR_HOME}/.local/share/containers/storage/tmp
    chown -R ${IOTGW_CTR_USER}:${IOTGW_CTR_USER} ${D}${IOTGW_CTR_HOME}

    # Linger: systemd-logind starts user@<uid>.service at boot for every name
    # in this directory, with no login session. /var/lib is the volatile-binds
    # overlay over the image's /var/lib, so a file shipped here stays visible
    # (the overlay's lower layer, or copied up by the bind fallback).
    install -d ${D}${localstatedir}/lib/systemd/linger
    install -m 0644 /dev/null ${D}${localstatedir}/lib/systemd/linger/${IOTGW_CTR_USER}

    # Quadlet search path of the principal's user manager
    # (podman-user-generator reads /etc/containers/systemd/users/<uid>).
    # Shipped empty: workloads add .container/.volume/.network units here.
    install -d -m 0755 ${D}${sysconfdir}/containers/systemd/users/${IOTGW_CTR_UID}
}

FILES:${PN} = " \
    ${IOTGW_CTR_HOME} \
    ${localstatedir}/lib/systemd/linger/${IOTGW_CTR_USER} \
    ${sysconfdir}/containers/systemd/users/${IOTGW_CTR_UID} \
"

# newuidmap/newgidmap (shadow) map the subordinate ranges; pasta gives the
# container network namespace its connectivity.
RDEPENDS:${PN} = "podman shadow passt"
