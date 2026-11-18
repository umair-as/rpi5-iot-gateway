SUMMARY = "IoT GW Production Image (Raspberry Pi 5)"
DESCRIPTION = "Production-focused image with essential services and no development/debug extras."

LICENSE = "MIT"

# Pull in common base
require iot-gw-image-base.inc

# Production metadata policy: do not expose build host identifier in /etc/buildinfo.
IOTGW_BUILDINFO_INCLUDE_BUILD_SYS = "0"

# Lean image features suitable for production
IMAGE_FEATURES += " \
    ssh-server-openssh \
    splash \
"

# Core functionality only
CORE_IMAGE_EXTRA_INSTALL += " \
    packagegroup-iot-gw-prod \
    ${@bb.utils.contains('IOTGW_ENABLE_OTBR','1',' otbr-rpi5','',d)} \
"

# Keep image smaller by avoiding extra free space
IMAGE_ROOTFS_EXTRA_SPACE = "524288"

# Production U-Boot posture (surface_reduce fit_enforce watchdog
# appliance_lockdown) is NOT set here. IOTGW_UBOOT_FEATURES is read by the
# u-boot and bootfiles recipes from the global datastore (local.conf), and an
# assignment in this image recipe is visible to this recipe alone: it would
# make the image's own check tautological while U-Boot is built without the
# lockdown. kas/uboot-prod-hardening.yml appends appliance_lockdown globally;
# the prod hygiene gate (iotgw-rootfs.bbclass) reads the same global value
# and fails the build when the token is missing.

# Production policy: lock audit rules after load (reboot required to change).
IOTGW_AUDIT_RULE_IMMUTABLE = "2"

# Fail the build on dev-only packages, drop-ins, ports, kernel fragments or a
# U-Boot without the lockdown (iotgw-rootfs.bbclass).
IOTGW_PROD_HYGIENE_GATE = "1"

# No password for root: "*" matches no password (pam_unix), so the serial
# console, newrole and any PAM password path refuse it. sshd runs with UsePAM
# yes and never inspects the hash, so only PermitRootLogin no (the prod sshd
# drop-in) keeps root off the network. Prod has no administrator: it is
# changed through OTA bundles (staged by the operator account below, or by
# A/B fallback) and by reflash. "!" would behave identically for keys; "*"
# is used so the account reads as "no password" rather than "locked".
IOTGW_ROOT_PASSWORD_HASH = "*"

# The OTA operator: the only login on prod. Key-only over SSH, lands in staff_t
# (seusers), may stage a bundle in /data/ota-tmp, drive RAUC over D-Bus and
# read the journal, and cannot elevate (no sudo entry, no password for
# newrole). IDs are fixed in the distro tables. The key is part of the image
# (AuthorizedKeysFile under /etc, 10-iotgw-prod-auth.conf), so an OTA update
# rotates or revokes it; a prod image without a key has no administrative
# path at all, so the build fails without one.
IOTGW_PROD_OPS_AUTH_KEYS_FILE ?= ""
EXTRA_USERS_PARAMS:append = " \
    groupadd -f -g 967 iotgw-ops; \
    useradd -u 967 -g 967 -G systemd-journal -d /home/iotgw-ops -m -s /bin/sh -K PASS_MAX_DAYS=99999 iotgw-ops; \
    usermod -p '*' iotgw-ops; \
"
iotgw_rootfs_prod_ops_access() {
    if [ -z "${IOTGW_PROD_OPS_AUTH_KEYS_FILE}" ] || [ ! -s "${IOTGW_PROD_OPS_AUTH_KEYS_FILE}" ]; then
        bbfatal "prod: IOTGW_PROD_OPS_AUTH_KEYS_FILE must name a non-empty authorized_keys file (kas/local.yml)"
    fi
    # Root-owned, world-readable: sshd reads it as the account.
    install -d -m 0755 ${IMAGE_ROOTFS}${sysconfdir}/ssh/authorized_keys.d
    install -m 0644 "${IOTGW_PROD_OPS_AUTH_KEYS_FILE}" ${IMAGE_ROOTFS}${sysconfdir}/ssh/authorized_keys.d/iotgw-ops
    grep -q '^ssh-' ${IMAGE_ROOTFS}${sysconfdir}/ssh/authorized_keys.d/iotgw-ops || bbfatal "prod: operator key file holds no public key"
    # D-Bus: let the operator uid drive the installer. The shared policy file
    # names only root and the updater; this account exists on prod alone.
    install -d ${IMAGE_ROOTFS}${sysconfdir}/dbus-1/system.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/dbus-1/system.d/de.pengutronix.rauc-iotgw-ops.conf <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="iotgw-ops">
    <allow send_destination="de.pengutronix.rauc"/>
  </policy>
</busconfig>
EOF
}
ROOTFS_POSTPROCESS_COMMAND:append = " iotgw_rootfs_prod_ops_access;"
