FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The U-Boot bootloader backend needs fw_printenv/fw_setenv and the compiled
# environment at runtime.
RDEPENDS:${PN} += "u-boot-fw-utils u-boot-env"

SRC_URI:append = " \
    file://99-iotgw-rauc-slots.rules \
    file://rauc-tpm2-pkcs11-store.service.conf \
    file://de.pengutronix.rauc-iotgw.conf \
    file://rauc-hardening.service.conf \
"

IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE ?= "file"
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "0"
# rauc.inc has no PACKAGECONFIG[pkcs11]; use the meson option directly.
# pkcs11_engine defaults to true in 1.15.x — disable it when not needed to
# avoid pulling in the OpenSSL engine for builds that don't use PKCS#11 keys.
EXTRA_OEMESON:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', '', ' -Dpkcs11_engine=false', d)}"

do_install:append() {
    # Stable RAUC slot names (/dev/disk/by-rauc-slot/*), created at
    # udev-trigger time without waiting for udev-settle.
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/99-iotgw-rauc-slots.rules \
        ${D}${sysconfdir}/udev/rules.d/99-iotgw-rauc-slots.rules

    # Restrict who may call the root RAUC service over D-Bus. meta-rauc's own
    # policy grants send_destination to context="default" - i.e. every local
    # process - to a root, unsandboxed installer. /etc/dbus-1/system.d is
    # included AFTER /usr/share/dbus-1/system.d by system.conf, so this file's
    # explicit <deny> revokes that grant. See the file header for why a
    # same-named replacement would NOT have worked.
    install -d ${D}${sysconfdir}/dbus-1/system.d
    install -m 0644 ${UNPACKDIR}/de.pengutronix.rauc-iotgw.conf \
        ${D}${sysconfdir}/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf

    # Conservative unit sandboxing. Numbered above the TPM drop-in so ordering
    # is explicit rather than incidental.
    install -d ${D}${sysconfdir}/systemd/system/rauc.service.d
    install -m 0644 ${UNPACKDIR}/rauc-hardening.service.conf \
        ${D}${sysconfdir}/systemd/system/rauc.service.d/20-iotgw-hardening.conf

    if ${@bb.utils.contains('IOTGW_RAUC_PKCS11_USES_TPM2', '1', 'true', 'false', d)}; then
        install -d ${D}${sysconfdir}/systemd/system/rauc.service.d
        sed -e "s|@IOTGW_TPM2_PKCS11_STORE@|${IOTGW_TPM2_PKCS11_STORE}|g" \
            -e "s|@IOTGW_RAUC_PKCS11_MODULE@|${IOTGW_RAUC_PKCS11_MODULE}|g" \
            ${UNPACKDIR}/rauc-tpm2-pkcs11-store.service.conf \
            > ${D}${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf
        chmod 0644 ${D}${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf
    fi

}

FILES:${PN}:append = " ${sysconfdir}/udev/rules.d/99-iotgw-rauc-slots.rules"
FILES:${PN}-service:append = " ${sysconfdir}/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf \
                               ${sysconfdir}/systemd/system/rauc.service.d/20-iotgw-hardening.conf \
                             "
FILES:${PN}-service:append = "${@bb.utils.contains('IOTGW_RAUC_PKCS11_USES_TPM2', '1', ' ${sysconfdir}/systemd/system/rauc.service.d/10-tpm2-pkcs11-store.conf', '', d)}"
RDEPENDS:${PN}-service:append = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', ' openssl-engines libp11', '', d)}"

# Keep RAUC available for D-Bus activation, but don't start it by default
SYSTEMD_AUTO_ENABLE:${PN}-service = "disable"
