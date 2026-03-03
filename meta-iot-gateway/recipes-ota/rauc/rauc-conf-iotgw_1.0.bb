SUMMARY = "RAUC system configuration for A/B updates"
DESCRIPTION = "Installs RAUC system.conf and keyring for the device. Compatible string and keyring are parameterized."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

# Provide the virtual config RAUC expects
RPROVIDES:${PN} += "virtual-rauc-conf"
INHIBIT_DEFAULT_DEPS = "1"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://iotgw-system.conf \
"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/rauc
    # Render system.conf from template using bundle-compatible
    sed "s|@COMPATIBLE@|${RAUC_BUNDLE_COMPATIBLE}|g" \
        ${WORKDIR}/iotgw-system.conf > ${D}${sysconfdir}/rauc/system.conf
    # Install device keyring (public cert).
    # Prefer RAUC_DEVICE_KEYRING; fallback to RAUC_CERT_FILE (dev setups often reuse it).
    keyring="${RAUC_DEVICE_KEYRING}"
    if [ -z "$keyring" ]; then
        keyring="${RAUC_CERT_FILE}"
    fi
    if [ -z "$keyring" ]; then
        echo "ERROR: Neither RAUC_DEVICE_KEYRING nor RAUC_CERT_FILE is set. Configure in kas/local.yml." >&2
        exit 1
    fi
    if [ ! -f "$keyring" ]; then
        echo "ERROR: Keyring file not found: $keyring" >&2
        exit 1
    fi
    install -m 0644 "$keyring" ${D}${sysconfdir}/rauc/ca.cert.pem
}

FILES:${PN} = "${sysconfdir}/rauc/system.conf ${sysconfdir}/rauc/ca.cert.pem"

# ota-certs provisions the streaming TLS certificates referenced in system.conf
RDEPENDS:${PN} += "ota-certs"
