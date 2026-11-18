# Central users/groups for IoT GW images (applied via extrausers in image recipe)

# No password by default: "*" matches nothing, so password logins (console,
# SSH password, newrole) fail while SSH public-key login is unaffected. A
# bench that needs console logins sets a hash in kas/local.yml (gitignored);
# a hash in this file would be public.
IOTGW_ROOT_PASSWORD_HASH ?= "*"

# EXTRA_USERS_PARAMS is expanded by a shell inside extrausers.bbclass before
# usermod sees it, which would delete every "$6", "$salt" and "$hash" of a crypt
# hash. Escaping here lets kas/local.yml carry the hash exactly as
# `openssl passwd -6` prints it; an already escaped value is accepted too.
def iotgw_password_field(d, var):
    return (d.getVar(var) or '*').replace('\\$', '$').replace('$', '\\$')

EXTRA_USERS_PARAMS:append = " \
    usermod -p '${@iotgw_password_field(d, 'IOTGW_ROOT_PASSWORD_HASH')}' root; \
    groupadd -f -r sudo; \
    groupadd -f -g 983 netdev; \
    groupadd -f -g 982 wireshark; \
    groupadd -f -g 981 podman; \
    groupadd -f -g 990 gpio; \
    groupadd -f -g 992 i2c; \
    groupadd -f -g 991 spi; \
    groupadd -f -g 998 ota; \
    groupadd -f -g 986 systemd-timesync; \
    useradd -r -u 991 -g systemd-timesync -d / -s /sbin/nologin systemd-timesync; \
"

# Subordinate UID/GID ranges are part of the /data format like the IDs in the
# tables: a rootless container store maps container IDs onto them, so they must
# not move between images. useradd allocates them in creation order, which
# differs per image, so the files are written here. Two principals may run
# rootless containers: the container service account (every image) and devel
# (dev and desktop). The blocks are disjoint and clear of every login and
# system ID.
IOTGW_SUBID_CTR = "iotgw-ctr:${IOTGW_CTR_SUBID_START}:${IOTGW_CTR_SUBID_COUNT}"
IOTGW_SUBID_DEVEL = "devel:100000:65536"
iotgw_rootfs_subids() {
    for f in subuid subgid; do
        printf '%s\n' "${IOTGW_SUBID_CTR}" > ${IMAGE_ROOTFS}${sysconfdir}/$f
        if grep -q '^devel:' ${IMAGE_ROOTFS}${sysconfdir}/passwd; then
            printf '%s\n' "${IOTGW_SUBID_DEVEL}" >> ${IMAGE_ROOTFS}${sysconfdir}/$f
        fi
        chmod 0644 ${IMAGE_ROOTFS}${sysconfdir}/$f
    done
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_subids;"
