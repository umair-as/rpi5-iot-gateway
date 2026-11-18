# Two things for the iotgw distro:
#
# 1. The project policy module `iotgw` (files/policy/iotgw.{te,if,fc}): the
#    RAUC domain, the OTA device-key type, the volatile-binds overlay mounter
#    domain and a few local rules. It is built INTO the refpolicy store, not
#    shipped as a separate .pp, so that its file contexts are part of the
#    generated file_contexts and selinux-image labels the rootfs with them at
#    build time. refpolicy's `make conf` lists every module found under
#    policy/modules/ as "module" unless an existing modules.conf says
#    otherwise, so copying the three files in before do_compile is enough.
#
# 2. Labels for the writable /data partition. The read-only root is labelled
#    at build time (selinux-image); /data is not part of the image and its
#    inodes come up unlabeled_t. These two files give every /data path a real
#    context, and iotgw-selinux-relabel applies them on the device. See
#    docs/SELINUX.md.
#
#      file_contexts.subs   aliases overlay uppers and bind sources to the
#                           paths they are seen at (/etc, /var/log/journal ...)
#      file_contexts.local  every other /data path: var_lib_t by default, plus
#                           the typed exceptions (OTA key, RAUC state)
#
#    Installed after semodule has built the store in do_install, so the build
#    does not overwrite them. The build store itself carries neither file
#    (checked in the RPM), and this image makes no policy changes on the
#    device: /etc/selinux is read-only vendor content, the policy store is
#    volatile, and policy changes ship in a build.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://policy/iotgw.te \
    file://policy/iotgw.if \
    file://policy/iotgw.fc \
    file://iotgw-file_contexts.subs \
    file://iotgw-file_contexts.local \
    file://0001-container-no-unconfined-domain-for-rootless-engines.patch \
"

# Three explicit installs: BitBake's shell parser rejects `for ext in te if fc`
# (`if` is a reserved word to it even as a loop item).
do_compile:prepend() {
    install -d ${S}/policy/modules/services
    install -m 0644 ${UNPACKDIR}/policy/iotgw.te ${S}/policy/modules/services/iotgw.te
    install -m 0644 ${UNPACKDIR}/policy/iotgw.if ${S}/policy/modules/services/iotgw.if
    install -m 0644 ${UNPACKDIR}/policy/iotgw.fc ${S}/policy/modules/services/iotgw.fc
}

# Belt and braces for the auto-listing: if an earlier modules.conf in the work
# dir predates the module, `make conf` keeps that file's entries and would not
# add ours. Only reached when do_compile runs after an unclean previous run.
do_compile:append() {
    if ! grep -q '^iotgw = ' ${S}/policy/modules.conf; then
        bbfatal "iotgw policy module missing from ${S}/policy/modules.conf after 'make conf'"
    fi
    if ! grep -q '^iotgw = module' ${S}/policy/modules.conf; then
        bbfatal "iotgw policy module is not enabled as a loadable module: $(grep '^iotgw = ' ${S}/policy/modules.conf)"
    fi
}

# Members of the admin group log in as staff_u, the SELinux user that may hold
# sysadm_r, so the sudoers ROLE=sysadm_r TYPE=sysadm_t rule can take them to
# sysadm_t. Everyone else keeps the __default__ user_u mapping.
#
# Written as a local store entry (what `semanage login -a` records) plus the two
# generated seusers it merges into, after semodule has built the store:
#  - not refpolicy's appconfig seusers: its build pipes that file through
#    `grep '^[a-z_]'`, which drops every %group entry;
#  - not before `semodule -B`: genhomedircon expands a %group through the build
#    host's group database and fails. A rebuild on the device regenerates the
#    same seusers from seusers.local, with the device's groups.
# Login mappings: the admin group (dev/desktop) and the OTA operator account
# (prod) log in as staff_u. The file is shared by every image. On dev and
# desktop, which have no iotgw-ops account, the mapping grants nothing, but
# libsemanage warns "user iotgw-ops not in password file" on every store
# rebuild (semodule -B). The warning is expected there.
IOTGW_SEUSERS_LINES = "%sudo:staff_u:s0-s0:c0.c1023 iotgw-ops:staff_u:s0-s0:c0.c1023"

do_install:append() {
    store=${D}${POLICY_STORE_ROOT}/${POLICY_NAME}/active
    : > $store/seusers.local
    for line in ${IOTGW_SEUSERS_LINES}; do
        echo "$line" >> $store/seusers.local
        for f in $store/seusers ${D}${sysconfdir}/selinux/${POLICY_NAME}/seusers; do
            if [ ! -f $f ]; then
                bbfatal "generated seusers missing: $f"
            fi
            grep -qxF "$line" $f || echo "$line" >> $f
        done
    done
    fcdir=${D}${sysconfdir}/selinux/${POLICY_NAME}/contexts/files
    install -m 0644 ${UNPACKDIR}/iotgw-file_contexts.subs ${fcdir}/file_contexts.subs
    install -m 0644 ${UNPACKDIR}/iotgw-file_contexts.local ${fcdir}/file_contexts.local
    # The module must have made it into the store, or the rootfs labels for
    # rauc_exec_t / iotgw_ota_key_t / iotgw_overlay_exec_t silently fall back
    # to bin_t / etc_t.
    if [ ! -d ${D}${POLICY_STORE_ROOT}/${POLICY_NAME}/active/modules/100/iotgw ]; then
        bbfatal "iotgw policy module not present in the built policy store"
    fi
}
