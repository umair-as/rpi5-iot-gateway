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

###### NetworkManager profiles placement
iotgw_rootfs_nm_profiles() {
    if [ -d ${IMAGE_ROOTFS}${datadir}/iotgw-nm/connections ]; then
        install -d ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections
        for f in ${IMAGE_ROOTFS}${datadir}/iotgw-nm/connections/*.nmconnection; do
            [ -e "$f" ] || continue
            install -m 0600 "$f" ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections/
        done
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_nm_profiles;"

###### NetworkManager conf.d drop-ins placement
iotgw_rootfs_nm_conf() {
    if [ -d ${IMAGE_ROOTFS}${datadir}/iotgw-nm/conf.d ]; then
        install -d ${IMAGE_ROOTFS}/etc/NetworkManager/conf.d
        for f in ${IMAGE_ROOTFS}${datadir}/iotgw-nm/conf.d/*.conf; do
            [ -e "$f" ] || continue
            install -m 0644 "$f" ${IMAGE_ROOTFS}/etc/NetworkManager/conf.d/
        done
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_nm_conf;"

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
iotgw_rootfs_sysctl() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-sysctl/90-iotgw.conf ]; then
        install -d ${IMAGE_ROOTFS}/etc/sysctl.d
        install -m 0644 ${IMAGE_ROOTFS}${datadir}/iotgw-sysctl/90-iotgw.conf \
            ${IMAGE_ROOTFS}/etc/sysctl.d/90-iotgw.conf
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_sysctl;"

###### nftables default rules
iotgw_rootfs_nftables() {
    if [ -e ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables.conf ]; then
        install -m 0644 ${IMAGE_ROOTFS}${datadir}/iotgw-firewall/nftables.conf \
            ${IMAGE_ROOTFS}/etc/nftables.conf
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_nftables;"

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
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_audit_rules;"

###### Bluetooth configuration directory mode alignment
iotgw_rootfs_bluetooth_mode() {
    if [ -d ${IMAGE_ROOTFS}/etc/bluetooth ]; then
        chmod 0555 ${IMAGE_ROOTFS}/etc/bluetooth || true
    fi
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_bluetooth_mode;"

###### Mask units that preset-all cannot disable (Yocto always runs --preset-mode=enable-only)
# NM installs its wants symlink via pkg_postinst before our preset is applied, so the
# disable directive in 90-iotgw.preset is silently ignored. An explicit mask is required.
iotgw_rootfs_mask_nm_wait_online() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/NetworkManager-wait-online.service
    # Also remove the wants symlink if NM's postinst left one
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_nm_wait_online;"

###### Disable systemd-network-generator for NetworkManager-only gateway profile
# We do not use systemd-networkd units in this distro profile. Keep boot path
# lean by masking the generator that emits networkd units from kernel cmdline.
iotgw_rootfs_mask_network_generator() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-network-generator.service
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_network_generator;"

###### Disable systemd-networkd stack for NetworkManager-only gateway profile
iotgw_rootfs_mask_networkd_stack() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.service
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.socket
    ln -snf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
}
ROOTFS_POSTPROCESS_COMMAND += " iotgw_rootfs_mask_networkd_stack;"

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
