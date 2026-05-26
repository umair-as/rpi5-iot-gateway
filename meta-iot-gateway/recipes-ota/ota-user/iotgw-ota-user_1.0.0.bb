# SPDX-License-Identifier: MIT
#
# iotgw-ota-user: Shared OTA sandbox user/group definition
#

SUMMARY = "Shared OTA sandbox user account"
DESCRIPTION = "Creates the dedicated ota system user/group used by RAUC streaming and OTA services."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
RECIPE_MAINTAINER = "Umair A.S <umair-as@users.noreply.github.com>"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit useradd

IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE ?= "0"
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "0"

# useradd-only recipe (no payload files)
ALLOW_EMPTY:${PN} = "1"
RPROVIDES:${PN} += "ota-user"

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r ota"
# Supplementary group 'iotgwtpm' (when TPM/PKCS#11 is enabled) is intentionally
# NOT listed via --groups here: the group is provided by iotgw-tpm-policy and
# may not yet exist in /etc/group when this useradd runs during rootfs
# assembly. A baked-in --groups iotgwtpm fails the whole useradd in that case,
# leaving no 'ota' user or group at all. The pkg_postinst below adds the
# supplementary group after both packages are installed.
USERADD_PARAM:${PN} = " \
    --system \
    --home /nonexistent \
    --no-create-home \
    --shell /bin/false \
    --gid ota \
    --comment 'OTA Update Daemon' \
    ota \
"

# When TPM/PKCS#11 is gated on, iotgw-tpm-policy is RDEPENDS-pulled so
# /etc/group contains the iotgwtpm group. The 'ota -> iotgwtpm' supplementary
# membership itself is added by ROOTFS_POSTPROCESS in iotgw-rootfs.bbclass
# (see IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS in iotgw-common.inc) -- race-free,
# does not depend on run-postinsts.service.
RDEPENDS:${PN} = " \
    ${@'iotgw-tpm-policy' if ((d.getVar('IOTGW_ENABLE_OTA_TPM_MTLS_EFFECTIVE') or '0') == '1' or (d.getVar('IOTGW_RAUC_PKCS11_USES_TPM2') or '0') == '1') else ''} \
"
