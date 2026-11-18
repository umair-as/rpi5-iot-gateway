# Common RootFS post-processing for IoT Gateway images
# Add focused, reusable hooks here and keep image recipes clean.

# Copy staged sudoers drop-in into place to avoid opkg directory ownership conflicts.
iotgw_rootfs_setup_sudoers() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-sudoers/devel ]; then
        install -d -m 0750 ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d
        install -m 0440 ${IMAGE_ROOTFS}${datadir}/iotgw-sudoers/devel \
            ${IMAGE_ROOTFS}${sysconfdir}/sudoers.d/devel
    fi
}

ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_setup_sudoers;"

###### Network topology (systemd-networkd) + wpa_supplicant Wi-Fi config are
###### shipped directly by iotgw-network-units into /etc; no rootfs placement
###### step is required.

###### Journald drop-in
iotgw_rootfs_journald() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-journald/iotgw.conf ]; then
        install -d ${IMAGE_ROOTFS}/etc/systemd/journald.conf.d
        install -m 0644 ${IMAGE_ROOTFS}${datadir}/iotgw-journald/iotgw.conf \
            ${IMAGE_ROOTFS}/etc/systemd/journald.conf.d/iotgw.conf
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_journald;"

###### Sysctl drop-in
# Recipes that ship sysctl fragments stage them under
# ${datadir}/iotgw-sysctl/<NN>-<name>.conf. We promote everything in that
# directory to /etc/sysctl.d/ at image-assembly time. systemd-sysctl applies
# files in lexical order, so the NN- prefix drives precedence.
iotgw_rootfs_sysctl() {
    install -d ${IMAGE_ROOTFS}/etc/sysctl.d

    [ -d ${IMAGE_ROOTFS}${datadir}/iotgw-sysctl ] || return 0

    for f in ${IMAGE_ROOTFS}${datadir}/iotgw-sysctl/*.conf; do
        [ -e "$f" ] || continue
        install -m 0644 "$f" ${IMAGE_ROOTFS}/etc/sysctl.d/
    done
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_sysctl;"

###### nftables default rules
# IOTGW_IMAGE_OTBR_WEBUI = "1" (dev, desktop) admits the OTBR web UI port; any
# other image, prod included, gets the placeholder removed and no :80 rule.
IOTGW_IMAGE_OTBR_WEBUI ??= "0"
iotgw_rootfs_nftables() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables.conf ]; then
        install -m 0644 ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables.conf \
            ${IMAGE_ROOTFS}/etc/nftables.conf
        if [ "${IOTGW_IMAGE_OTBR_WEBUI}" = "1" ] && \
           [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables-otbr-webui.conf ]; then
            sed -i -e '/@OTBR_WEBUI_RULES@/r ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables-otbr-webui.conf' \
                   ${IMAGE_ROOTFS}/etc/nftables.conf
        fi
        sed -i '/@OTBR_WEBUI_RULES@/d' ${IMAGE_ROOTFS}/etc/nftables.conf
        if grep -q '@[A-Z_]*@' ${IMAGE_ROOTFS}/etc/nftables.conf; then
            bbfatal "iotgw-firewall: unexpanded placeholder left in /etc/nftables.conf"
        fi
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_nftables;"

###### Prod hygiene gate: no dev-only packages, drop-ins or ports in a prod image
# Dev-only content (the OTBR web UI, nmap, iperf3, the crash-debug sysctl, the
# dev-friendly sshd policy) can reach prod through shared packagegroups and
# global toggles. Each is kept out by construction; this gate turns the next
# leak into a build failure instead of a finding. Enabled by the prod image recipe (IOTGW_PROD_HYGIENE_GATE = "1").
IOTGW_PROD_HYGIENE_GATE ??= "0"
IOTGW_PROD_FORBIDDEN_PATHS ??= " \
    ${bindir}/node ${datadir}/otbr-webui \
    ${bindir}/nmap ${bindir}/iperf3 ${bindir}/tcpdump ${bindir}/tshark ${bindir}/wireshark \
    ${bindir}/gdb ${bindir}/strace ${bindir}/valgrind ${bindir}/perf \
    ${sysconfdir}/sysctl.d/95-iotgw-crash-debug.conf \
    /home/devel ${sysconfdir}/sudoers.d/devel ${sysconfdir}/sudoers.d/010-devel \
    ${libdir}/libEGL.so.1 ${libdir}/libGLESv2.so.2 ${libdir}/libgbm.so.1 ${libdir}/dri \
    ${bindir}/kmscube \
    ${sysconfdir}/systemd/system/sockets.target.wants/podman.socket \
    ${sysconfdir}/systemd/system/multi-user.target.wants/podman.service \
    ${bindir}/slirp4netns ${bindir}/docker \
    ${sbindir}/mosquitto ${bindir}/mosquitto ${systemd_system_unitdir}/mosquitto.service \
    /root/.ssh/authorized_keys \
"
# GL userspace above: the headless build keeps DISTRO_FEATURES opengl so the
# dev image can carry Mesa (v3d) for GPU work, and that feature is shared with
# prod. Prod has no consumer of the GPU, so Mesa reaching it means a package
# picked up a GL dependency; the gate fails the build instead of shipping it.
iotgw_rootfs_prod_hygiene() {
    [ "${IOTGW_PROD_HYGIENE_GATE}" = "1" ] || return 0
    local bad="" p
    for p in ${IOTGW_PROD_FORBIDDEN_PATHS}; do
        [ -e "${IMAGE_ROOTFS}$p" ] && bad="$bad $p"
    done
    [ -z "$bad" ] || bbfatal "prod hygiene: dev-only content present in the prod rootfs:$bad"
    if [ "${IOTGW_ENABLE_CRASH_DEBUG_DEV}" = "1" ]; then
        bbfatal "prod hygiene: IOTGW_ENABLE_CRASH_DEBUG_DEV=1 while building a prod image (kas/local.yml sets it; the prod kas overlay forces it to 0 - is the overlay in the composition?)"
    fi
    if [ ! -e ${IMAGE_ROOTFS}${sysconfdir}/ssh/sshd_config.d/10-iotgw-prod-auth.conf ]; then
        bbfatal "prod hygiene: sshd prod policy drop-in missing (iotgw-sshd-hardening-prod not installed)"
    fi
    # Hardening content must be present, not only dev content absent: a
    # packagegroup installed by the wrong tier fails silently otherwise.
    # iotgw-audit stages its rules under ${datadir}; iotgw_rootfs_audit_rules
    # (appended after this gate) deploys them into ${sysconfdir}/audit, so the
    # staged copy is checked here.
    for p in ${sysconfdir}/sysctl.d/99-iotgw-hardening.conf \
             ${sysconfdir}/modprobe.d/iotgw-blacklist.conf \
             ${sysconfdir}/systemd/system/wpa_supplicant@${IOTGW_WIFI_IFACE}.service.d/override.conf \
             ${datadir}/iotgw-audit/iotgw.rules \
             ${localstatedir}/lib/systemd/linger/iotgw-ctr ${bindir}/pasta \
             ${datadir}/iotgw-audit/auditd.conf; do
        [ -e "${IMAGE_ROOTFS}$p" ] || bad="$bad $p"
    done
    [ -z "$bad" ] || bbfatal "prod hygiene: hardening content missing from the prod rootfs (packagegroup-iot-gw-security not installed?):$bad"
    if grep -qE '^[^#]*dport[[:space:]]+80[[:space:]]' ${IMAGE_ROOTFS}${sysconfdir}/nftables.conf 2>/dev/null; then
        bbfatal "prod hygiene: firewall admits tcp/80 (OTBR web UI rule) in a prod image"
    fi
    # Kernel and U-Boot are one recipe per composition and read these two
    # variables from the global datastore, the same values this image sees.
    # The dev fragments and the lockdown token are decided by the kas
    # composition (kas/uboot-prod-hardening.yml), not by this recipe, so a
    # prod image from the wrong composition is caught here.
    local f
    for f in igw_observability_dev igw_crash_debug_dev igw_btf_core_dev; do
        case " $(echo "${IOTGW_KERNEL_FEATURES}" | tr ',' ' ') " in
            *" $f "*) bbfatal "prod hygiene: dev kernel fragment $f in IOTGW_KERNEL_FEATURES (kas/uboot-prod-hardening.yml not in the composition?)" ;;
        esac
    done
    if [ "${IOTGW_ENABLE_BTF_CORE_DEV}" = "1" ]; then
        bbfatal "prod hygiene: IOTGW_ENABLE_BTF_CORE_DEV=1 while building a prod image"
    fi
    for f in appliance_lockdown fit_enforce; do
        case " ${IOTGW_UBOOT_FEATURES} " in
            *" $f "*) ;;
            *) bbfatal "prod hygiene: IOTGW_UBOOT_FEATURES lacks $f (kas/uboot-prod-hardening.yml not in the composition?)" ;;
        esac
    done
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_prod_hygiene;"

# Root has no password in prod. Checked after extrausers has applied the
# usermod (its set_user_group is added with +=; :append runs after all +=).
iotgw_rootfs_prod_root_locked() {
    [ "${IOTGW_PROD_HYGIENE_GATE}" = "1" ] || return 0
    if [ "$(awk -F: '$1=="root"{print $2}' ${IMAGE_ROOTFS}${sysconfdir}/shadow)" != "*" ]; then
        bbfatal "prod hygiene: root has a password in the prod image (IOTGW_ROOT_PASSWORD_HASH must be \"*\")"
    fi
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_prod_root_locked;"

# A password field is a lock marker or a well-formed crypt(5) hash. Anything
# else matches no password, which locks the console without any build error.
# Runs after extrausers for the same reason as the check above.
iotgw_rootfs_password_fields() {
    for user in root devel; do
        grep -q "^$user:" ${IMAGE_ROOTFS}${sysconfdir}/shadow || continue
        field=$(awk -F: -v u="$user" '$1==u{print $2}' ${IMAGE_ROOTFS}${sysconfdir}/shadow)
        case "$field" in
            '*'|'!'*) ;;
            '$'[0-9a-z]*'$'*'$'*) ;;
            *) bbfatal "shadow: $user has a malformed password field (check IOTGW_*_PASSWORD_HASH and its escaping)" ;;
        esac
    done
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_password_fields;"

# Credentials from kas/local.yml stay out of git, not out of the image: a
# password hash or a Wi-Fi key is in the rootfs, the .wic and every RAUC bundle
# built from it. Say so on every build that carries one, without printing it.
# A dev image with no password at all is valid (SSH keys only), so that case
# warns rather than fails. Reads the staged rootfs, after extrausers.
python iotgw_rootfs_credential_warnings() {
    import glob, os, re
    rootfs = d.getVar('IMAGE_ROOTFS')
    image = d.getVar('PN')
    shadow = {}
    etc = os.path.join(rootfs, d.getVar('sysconfdir').lstrip('/'))
    with open(os.path.join(etc, 'shadow')) as f:
        for line in f:
            fields = line.split(':')
            if len(fields) > 1:
                shadow[fields[0]] = fields[1]
    hashed = [u for u in ('root', 'devel', 'iotgw-ops')
              if u in shadow and shadow[u].startswith('$')]
    for user in hashed:
        bb.warn('%s: %s has a password hash in the image; it is in the .wic and '
                'every bundle built from it, do not distribute them' % (image, user))
    if 'devel' in shadow and not hashed:
        bb.warn('%s: no account has a password (console and newrole logins '
                'fail, SSH keys only); set IOTGW_ROOT_PASSWORD_HASH or '
                'IOTGW_DEVEL_PASSWORD_HASH in kas/local.yml if the bench needs '
                'one' % image)
    keyline = re.compile(r'^\s*(psk|sae_password|password)=', re.M)
    for conf in glob.glob(os.path.join(etc, 'wpa_supplicant/*.conf')):
        with open(conf) as f:
            if keyline.search(f.read()):
                bb.warn('%s: %s carries a Wi-Fi key in plain text; it is in the '
                        '.wic and every bundle built from it' %
                        (image, os.path.relpath(conf, rootfs)))
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_credential_warnings;"

# The busybox setuid-root binary is trimmed in every image: the applets it
# carried come from shadow, util-linux and iputils.
iotgw_rootfs_no_suid_busybox() {
    if [ -e ${IMAGE_ROOTFS}${base_bindir}/busybox.suid ] || [ -u ${IMAGE_ROOTFS}${base_bindir}/busybox ]; then
        bbfatal "busybox is setuid in the image: iotgw-no-suid-applets.cfg did not take effect"
    fi
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_no_suid_busybox;"

###### Audit rules deployment
# auditd owns /etc/audit and /etc/audit/rules.d — we cannot package into those dirs
# directly from iotgw-audit without a file conflict. Deploy at rootfs build time instead.
iotgw_rootfs_audit_rules() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-audit/iotgw.rules ]; then
        audit_lock_mode=""
        install -d -m 0750 ${IMAGE_ROOTFS}${sysconfdir}/audit/rules.d
        install -m 0640 ${IMAGE_ROOTFS}${datadir}/iotgw-audit/iotgw.rules \
            ${IMAGE_ROOTFS}${sysconfdir}/audit/rules.d/iotgw.rules
        audit_lock_mode="${IOTGW_AUDIT_RULE_IMMUTABLE}"
        case "${audit_lock_mode}" in
            1|2) ;;
            *) audit_lock_mode="1" ;;
        esac
        sed -i -E "s/^-e[[:space:]]+[0-9]+$/-e ${audit_lock_mode}/" \
            ${IMAGE_ROOTFS}${sysconfdir}/audit/rules.d/iotgw.rules
    fi

    # Override the auditd package-default auditd.conf with the layer's retention/disk
    # policy (non-fatal disk actions; logs persist on /data via iotgw-log-persist).
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-audit/auditd.conf ]; then
        install -m 0640 ${IMAGE_ROOTFS}${datadir}/iotgw-audit/auditd.conf \
            ${IMAGE_ROOTFS}${sysconfdir}/audit/auditd.conf
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_audit_rules;"

###### SELinux: no unexpected permissive domains in the shipped policy
# A `permissive <domain>;` statement is part of the policy and takes effect
# whatever the kernel configuration (the kernel reads the policy's permissive
# map; CONFIG_SECURITY_SELINUX_DEVELOP only gates the global switch). The
# staging allowlist IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED (distro include)
# names the domains still being collected on an enforcing trial; anything else
# fails the image, and the list itself must be empty before the enforcing flip.
# The store's CIL files are bzip2-compressed by refpolicy's install.
do_rootfs[depends] += "bzip2-replacement-native:do_populate_sysroot"
iotgw_rootfs_selinux_permissive_gate() {
    local store cil doms found unexpected d
    store=$(ls -d ${IMAGE_ROOTFS}${localstatedir}/lib/selinux/*/active/modules 2>/dev/null | head -n1)
    [ -n "$store" ] || return 0
    found=""
    for cil in "$store"/*/*/cil; do
        [ -f "$cil" ] || continue
        if bzip2 -t "$cil" 2>/dev/null; then
            doms=$(bzip2 -dc "$cil" | sed -n 's/^(typepermissive \([A-Za-z0-9_]*\))/\1/p')
        else
            doms=$(sed -n 's/^(typepermissive \([A-Za-z0-9_]*\))/\1/p' "$cil")
        fi
        found="$found $doms"
    done
    # Prod ships no permissive domain at all: neither one in the policy nor an
    # allowlist that would let one through.
    if [ "${IOTGW_PROD_HYGIENE_GATE}" = "1" ]; then
        if [ -n "$(echo ${IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED})" ]; then
            bbfatal "SELinux: IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED is not empty in a prod image:$(echo ${IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED} | sed 's/^/ /')"
        fi
        if [ -n "$(echo $found)" ]; then
            bbfatal "SELinux: a prod image may not ship permissive domains:$(echo $found | sed 's/^/ /')"
        fi
    fi
    unexpected=""
    for d in $found; do
        case " ${IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED} " in
            *" $d "*) ;;
            *) unexpected="$unexpected $d" ;;
        esac
    done
    if [ -n "$unexpected" ]; then
        bbfatal "SELinux policy declares permissive domain(s) not in IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED:$unexpected"
    fi
    if [ -n "$(echo $found)" ]; then
        bbwarn "SELinux: staging permissive domains shipped in this image:$(echo $found). Remove them (and empty IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED) before the enforcing flip."
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_selinux_permissive_gate;"

###### Bluetooth configuration directory mode alignment
iotgw_rootfs_bluetooth_mode() {
    if [ -d ${IMAGE_ROOTFS}/etc/bluetooth ]; then
        chmod 0555 ${IMAGE_ROOTFS}/etc/bluetooth || true
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_bluetooth_mode;"

###### Keep boot lean under the systemd-networkd stack.
# systemd-networkd + systemd-resolved are the active stack (enabled via
# 90-iotgw.preset). Mask exactly one auxiliary unit: systemd-networkd-wait-online.
# ota-updater pulls network-online.target, so an active wait-online
# would block boot until every managed link (including Wi-Fi association, which
# may never complete if no PSK is configured) becomes routable — up to its
# ~120s timeout. Masking it makes network-online.target a trivial sync point,
# so it starts without waiting on the network (prior lean-boot
# posture). This is one of two intentional masks (see wpa_supplicant.service
# below); systemd 259's preset-all emits a benign "is masked" notice for it,
# filtered via IMAGE_LOG_CHECK_EXCLUDES in iot-gw-image-base.inc.
# NOTE: do NOT mask systemd-networkd.service/.socket — those are required.
iotgw_rootfs_mask_networkd_wait_online() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_networkd_wait_online;"

###### Mask the unconfined D-Bus-activatable wpa_supplicant.service singleton.
# The active Wi-Fi path uses the hardened wpa_supplicant@wlan0.service
# instance (drop-in from iotgw-hardening); the wpa-supplicant package still
# ships the singleton wpa_supplicant.service (AUTO_ENABLE=disable, unmasked)
# with its fi.w1.wpa_supplicant1 D-Bus activation file. Anything that bus-
# activates it would run a network-facing daemon without the
# NoNewPrivileges/Protect*/Restrict* confinement applied to the @wlan0
# instance. Mask it so D-Bus activation cannot start it. This is the second
# of two intentional masks in this class (see systemd-networkd-wait-online
# above).
iotgw_rootfs_mask_wpa_supplicant_singleton() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/wpa_supplicant.service
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_wpa_supplicant_singleton;"

###### Apply our user-unit presets after recipes have enabled user units.
# systemd.bbclass runs `systemctl --global enable` for every SYSTEMD_SERVICE
# name that also exists as a user unit (podman.service/podman.socket), and an
# explicit enable is not undone by a preset. Without this step the "disable"
# lines in our user-preset files never take effect: every login session would
# start a rootless podman API for that user.
iotgw_rootfs_user_presets() {
    for f in ${IMAGE_ROOTFS}${systemd_unitdir}/user-preset/[0-9]*-iotgw-*.preset; do
        [ -f "$f" ] || continue
        for unit in $(awk '$1 == "disable" { print $2 }' "$f"); do
            if [ -e ${IMAGE_ROOTFS}${systemd_user_unitdir}/$unit ]; then
                systemctl --root=${IMAGE_ROOTFS} --global disable "$unit"
            fi
        done
    done
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_user_presets;"

###### Optional vconsole setup masking (headless/serial-focused images)
iotgw_rootfs_mask_vconsole_setup() {
    if [ "${IOTGW_DISABLE_VCONSOLE_SETUP}" = "1" ]; then
        install -d ${IMAGE_ROOTFS}/etc/systemd/system
        ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-vconsole-setup.service
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_vconsole_setup;"

###### Optional legacy RAUC mark-good unit masking
iotgw_rootfs_mask_rauc_mark_good() {
    if [ "${IOTGW_DISABLE_RAUC_MARK_GOOD}" = "1" ]; then
        install -d ${IMAGE_ROOTFS}/etc/systemd/system
        ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/rauc-mark-good.service
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_rauc_mark_good;"

###### SELinux: mask the meta-selinux first-boot autorelabel unit
# selinux-autorelabel is a hard RDEPENDS of packagegroup-core-selinux, so it
# cannot be left out of the image. It is inert here: the root is labelled at
# build time (selinux-image) and /.autorelabel cannot exist on the dm-verity
# root. If it ever ran, `fixfiles -F relabel /` would rewrite labels across
# the assembled /etc instead of the build-time ones. Mask it (WantedBy=sysinit.target: a masked
# Wants= dependency is skipped, not a failure). /data is labelled by
# iotgw-selinux-relabel instead.
iotgw_rootfs_mask_selinux_autorelabel() {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'selinux', 'true', 'false', d)}; then
        install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
        ln -snf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/selinux-autorelabel.service
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_selinux_autorelabel;"

###### OTA updater config ownership/mode
# ota-updater runs as User=ota/Group=ota and needs read access to /etc/ota/updater.conf.
# Enforce deterministic rootfs permissions here to avoid host-dependent group resolution.
iotgw_rootfs_ota_updater_config_perms() {
    cfg="${IMAGE_ROOTFS}/etc/ota/updater.conf"
    grp_file="${IMAGE_ROOTFS}/etc/group"
    ota_gid=""

    [ -e "${cfg}" ] || return 0

    if [ ! -e "${grp_file}" ] || ! grep -q '^ota:' "${grp_file}"; then
        bbfatal "Expected ota group in rootfs when ${cfg} is present"
    fi

    ota_gid="$(awk -F: '/^ota:/{print $3; exit}' "${grp_file}")"
    if [ -z "${ota_gid}" ]; then
        bbfatal "Failed to resolve ota group id from ${grp_file}"
    fi

    chown "root:${ota_gid}" "${cfg}"
    chmod 0640 "${cfg}"
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_ota_updater_config_perms;"

###### Deterministic build info (/etc/buildinfo)
iotgw_rootfs_buildinfo() {
    install -d ${IMAGE_ROOTFS}/etc
    {
        echo "DISTRO=${DISTRO}"
        echo "DISTRO_NAME=${DISTRO_NAME}"
        echo "DISTRO_VERSION=${DISTRO_VERSION}"
        echo "DISTRO_CODENAME=${DISTRO_CODENAME}"
        echo "IOTGW_VERSION=${IOTGW_VERSION}"
        echo "IOTGW_RELEASE_TRACK=${IOTGW_RELEASE_TRACK}"
        echo "IOTGW_BUILD_ID=${IOTGW_BUILD_ID}"
        echo "MACHINE=${MACHINE}"
        echo "TUNE_PKGARCH=${TUNE_PKGARCH}"
        echo "IMAGE_BASENAME=${IMAGE_BASENAME}"
        echo "IMAGE_NAME=${IMAGE_NAME}"
        echo "RAUC_BUNDLE_VERSION=${RAUC_BUNDLE_VERSION}"
        echo "RAUC_BUNDLE_COMPATIBLE=${RAUC_BUNDLE_COMPATIBLE}"
        if [ "${IOTGW_BUILDINFO_INCLUDE_BUILD_SYS}" = "1" ]; then
            echo "BUILD_SYS=${BUILD_SYS}"
        fi
    } > ${IMAGE_ROOTFS}/etc/buildinfo

    # Provide a single-line version file for compatibility with tools expecting /etc/version
    # Use IMAGE_NAME to include timestamped build identifier
    echo "${IMAGE_NAME}" > ${IMAGE_ROOTFS}/etc/version
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_buildinfo;"

# Layer revisions, appended to the same file. oe-core's image-buildinfo class
# writes /etc/buildinfo too, so it is not inherited: the two writers would
# clobber each other depending on order. Name, branch and revision only — the
# layer path is a build-host path and stays out of the image (see the prod
# BUILD_SYS policy in docs/SECURITY.md). Like oe-core's class, the revisions are
# excluded from the task signature, so a layer commit that changes nothing in
# the image does not force a rootfs rebuild; the file records the layers as of
# the last do_rootfs run.
python iotgw_rootfs_buildinfo_layers() {
    import os
    import oe.buildcfg
    path = os.path.join(d.getVar('IMAGE_ROOTFS'), 'etc', 'buildinfo')
    with open(path, 'a') as stream:
        for _path, name, branch, rev, modified in oe.buildcfg.get_layer_revisions(d):
            stream.write("LAYER_%s=%s:%s%s\n" % (name.replace('-', '_'), branch or '<detached>',
                                                rev, ' (modified)' if modified else ''))
}
iotgw_rootfs_buildinfo_layers[vardepsexclude] += "BBLAYERS"
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_buildinfo_layers;"

# oe-core's rootfs_reproducible hook rewrites /etc/version from SOURCE_DATE_EPOCH
# near the end of do_rootfs. Re-apply our image identifier after do_rootfs so
# tools see the real image build id instead of the reproducible timestamp token.
iotgw_rootfs_version_finalize() {
    install -d ${IMAGE_ROOTFS}/etc
    echo "${IMAGE_NAME}" > ${IMAGE_ROOTFS}/etc/version
}
do_rootfs[postfuncs] += "iotgw_rootfs_version_finalize"

# Ensure interactive shell defaults are present for operator users.
# Some user-creation flows may skip /etc/skel materialization for devel.
iotgw_rootfs_seed_bashrc() {
    if [ -f ${IMAGE_ROOTFS}/etc/skel/.bashrc ]; then
        if [ -d ${IMAGE_ROOTFS}/home/devel ] && [ ! -f ${IMAGE_ROOTFS}/home/devel/.bashrc ]; then
            install -m 0644 ${IMAGE_ROOTFS}/etc/skel/.bashrc ${IMAGE_ROOTFS}/home/devel/.bashrc
        fi
        install -d ${IMAGE_ROOTFS}/root
        install -m 0644 ${IMAGE_ROOTFS}/etc/skel/.bashrc ${IMAGE_ROOTFS}/root/.bashrc
    fi
}
do_rootfs[postfuncs] += "iotgw_rootfs_seed_bashrc"

# -----------------------------------------------------------------------------
# Supplementary group membership reconciliation
# -----------------------------------------------------------------------------
# Why: USERADD_PARAM's `--groups <X>` is racy when <X> is created by another
# recipe -- failure is atomic and silently loses the entire useradd. This
# block mutates /etc/group at ROOTFS_POSTPROCESS time, after all package
# useradd/groupadd processing has completed. Race-free, deterministic, and
# does not depend on run-postinsts.service (absent from prod images).
#
# Set IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS from distro/feature config, gated on
# the relevant toggles. Space-separated <user>:<group> pairs. Names must
# match ^[A-Za-z_][A-Za-z0-9_-]*\$?$ (POSIX form); validated at parse time.
# A pair that names a missing user or group is fatal -- if a feature gate
# asked for the membership but either side is absent, the image is
# internally inconsistent and we want to fail loudly.
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS ??= ""

python () {
    import re
    NAME_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_-]*\$?$')
    spec = (d.getVar('IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS') or '').split()
    for pair in spec:
        if ':' not in pair:
            bb.fatal("IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS: '%s' is not <user>:<group>" % pair)
        user, group = pair.split(':', 1)
        if not NAME_RE.match(user):
            bb.fatal("IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS: invalid user name '%s'" % user)
        if not NAME_RE.match(group):
            bb.fatal("IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS: invalid group name '%s'" % group)
}

iotgw_rootfs_supplementary_groups() {
    local group_file="${IMAGE_ROOTFS}${sysconfdir}/group"
    local gshadow_file="${IMAGE_ROOTFS}${sysconfdir}/gshadow"
    local passwd_file="${IMAGE_ROOTFS}${sysconfdir}/passwd"
    local pair user group tmp target

    [ -z "${IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS}" ] && return 0

    for pair in ${IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS}; do
        user="${pair%%:*}"
        group="${pair##*:}"

        if ! grep -q "^${user}:" "${passwd_file}"; then
            bbfatal "iotgw-supplementary-group: user '${user}' missing from rootfs ${passwd_file#${IMAGE_ROOTFS}}"
        fi
        if ! grep -q "^${group}:" "${group_file}"; then
            bbfatal "iotgw-supplementary-group: group '${group}' missing from rootfs ${group_file#${IMAGE_ROOTFS}}"
        fi

        # /etc/group and /etc/gshadow BOTH carry the member list (field 4) and
        # must stay in sync. Updating only /etc/group leaves the pair
        # inconsistent — `grpck` reports "<user> is a member of the '<group>'
        # group in /etc/group but not in /etc/gshadow", which is what surfaced
        # as Lynis AUTH-9216 on the dev image. NSS reads /etc/group, so the
        # membership itself works; the inconsistency is an integrity signal and
        # trips group-management tooling.
        for target in "${group_file}" "${gshadow_file}"; do
            [ -f "${target}" ] || continue

            tmp="${target}.iotgw-supp-tmp"
            awk -F: -v g="${group}" -v u="${user}" '
            BEGIN { OFS=":" }
            $1 == g {
                n = split($4, members, ",")
                found = 0
                for (i = 1; i <= n; i++) if (members[i] == u) { found = 1; break }
                if (!found) {
                    if ($4 == "") $4 = u
                    else          $4 = $4 "," u
                }
            }
            { print }
            ' "${target}" > "${tmp}"

            # Carry the original mode/ownership onto the replacement BEFORE
            # moving it into place. Two traps here, both hit during testing:
            #   * a plain `mv` takes the tmp file's umask mode — on /etc/gshadow
            #     (0400, root-only, holds group password hashes) that silently
            #     widens permissions;
            #   * redirecting into the original instead (`cat tmp > target`)
            #     preserves the mode but FAILS on a 0400 file, and fails
            #     silently — the loop continued and still logged success.
            # chmod/chown the temp file then mv: mv needs write permission on
            # the directory, not on the target file, so it works at any mode.
            chmod --reference="${target}" "${tmp}"
            chown --reference="${target}" "${tmp}" 2>/dev/null || true
            if ! mv "${tmp}" "${target}"; then
                rm -f "${tmp}"
                bbfatal "iotgw-supplementary-group: failed to update ${target#${IMAGE_ROOTFS}} for '${user}' -> '${group}'"
            fi
        done
        bbnote "iotgw-supplementary-group: applied '${user}' -> '${group}'"
    done
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_supplementary_groups;"

# -----------------------------------------------------------------------------
# Root account password-aging exemption
# -----------------------------------------------------------------------------
# The image ships root's shadow entry ALREADY EXPIRED. Two mechanisms combine:
#
#   1. iotgw-users.inc runs `usermod -p '<hash>' root`. root's base-passwd
#      shadow entry carries no aging fields, so usermod fills them from our
#      hardened /etc/login.defs (shadow_%.bbappend: PASS_MIN_DAYS 7,
#      PASS_MAX_DAYS 90, PASS_WARN_AGE 14).
#   2. Reproducible builds pin sp_lstchg to SOURCE_DATE_EPOCH -> 15069 days
#      (2011-04-05). 90 days later is 2011-07-04.
#
# Result on target: `root 15069 7 90 14` — a password that expired long
# before the build ran. Nothing at runtime rewrites the entry (/etc is a
# volatile overlay over the read-only root; writes never persist), so without
# the fix below root's password is expired on every boot.
#
# The same aging hit weston-init's useradd account (born expired, PAM refused
# the session, status=224/PAM; see
# recipes-graphics/weston/files/iotgw-weston-no-pam.conf). Weston dropped its
# PAM session; root cannot, because its PAM session is the recovery path.
#
# The fix is deliberately scoped to root's /etc/shadow ENTRY, not to
# /etc/login.defs:
#   * login.defs keeps PASS_MAX_DAYS 90, so the hardening posture that Lynis
#     AUTH-9286 checks — and every interactive account created later —
#     is unchanged;
#   * only the single account that must never be locked out is exempted.
# This mirrors the existing precedent for `devel`, which is created with
# `useradd -K PASS_MAX_DAYS=99999` in iotgw-dev-users.inc.
#
# 99999 matches that precedent and shadow's own "never expires" convention.
# Set IOTGW_ROOT_PASSWORD_AGING = "1" to keep the aging fields as-is.
IOTGW_ROOT_PASSWORD_AGING ??= "0"

iotgw_rootfs_root_password_aging() {
    local shadow_file="${IMAGE_ROOTFS}${sysconfdir}/shadow"
    local tmp

    [ "${IOTGW_ROOT_PASSWORD_AGING}" = "1" ] && return 0
    [ -f "${shadow_file}" ] || return 0

    if ! grep -q '^root:' "${shadow_file}"; then
        bbfatal "iotgw-root-password-aging: no root entry in ${shadow_file#${IMAGE_ROOTFS}}"
    fi

    tmp="${shadow_file}.iotgw-aging-tmp"

    # Field 5 is sp_max (maximum password age in days). Leave sp_lstchg (3),
    # sp_min (4) and sp_warn (6) alone: with sp_max unlimited they no longer
    # gate authentication, and rewriting sp_lstchg would break reproducibility.
    awk -F: -v OFS=: '$1 == "root" { $5 = "99999" } { print }' \
        "${shadow_file}" > "${tmp}"

    # Same mode/ownership trap as the supplementary-group reconciler above:
    # /etc/shadow is 0400 root-only, so `cat tmp > target` fails (silently, in
    # a shell function), and a bare `mv` would take the tmp file's umask mode.
    # chmod/chown the temp file, then mv — mv needs write permission on the
    # directory, not on the target.
    chmod --reference="${shadow_file}" "${tmp}"
    chown --reference="${shadow_file}" "${tmp}" 2>/dev/null || true
    if ! mv "${tmp}" "${shadow_file}"; then
        rm -f "${tmp}"
        bbfatal "iotgw-root-password-aging: failed to update ${shadow_file#${IMAGE_ROOTFS}}"
    fi

    if ! awk -F: '$1 == "root" && $5 == "99999" { found = 1 } END { exit !found }' \
            "${shadow_file}"; then
        bbfatal "iotgw-root-password-aging: root sp_max is not 99999 after rewrite"
    fi

    bbnote "iotgw-root-password-aging: root exempted from PASS_MAX_DAYS (sp_max=99999)"
}

# postfuncs, not ROOTFS_POSTPROCESS_COMMAND: oe-core's own rootfs postprocess
# steps (and the extrausers processing that creates the entry) must have run
# first, or the rewrite lands on a shadow file that is then replaced.
do_rootfs[postfuncs] += "iotgw_rootfs_root_password_aging"
