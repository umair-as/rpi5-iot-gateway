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

IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE ?= "file"
IOTGW_RAUC_PKCS11_USES_TPM2 ?= "0"
IOTGW_RAUC_STREAMING_TLS_KEY = "${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE', 'pkcs11', d.getVar('IOTGW_RAUC_PKCS11_TLS_KEY') or '', '/etc/ota/device.key', d)}"
IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION ?= "0"
IOTGW_RAUC_ENCRYPTION_KEY ?= ""
IOTGW_RAUC_ENCRYPTION_CERT ?= ""

do_install() {
    if [ "${IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE}" = "pkcs11" ] && [ "${IOTGW_RAUC_PKCS11_USES_TPM2}" = "1" ]; then
        case "${IOTGW_RAUC_STREAMING_TLS_KEY}" in
            *"module-path="*)
                echo "ERROR: TPM2 PKCS#11 streaming key URI must not include module-path when PKCS11_MODULE_PATH service env is used." >&2
                echo "       Current: ${IOTGW_RAUC_STREAMING_TLS_KEY}" >&2
                exit 1
                ;;
        esac
        case "${IOTGW_RAUC_STREAMING_TLS_KEY}" in
            *"pin-source=file:/etc/ota/pkcs11-pin"*|*"pin-value="*) ;;
            *)
                echo "ERROR: TPM2 PKCS#11 streaming key URI must include pin-source=file:/etc/ota/pkcs11-pin (preferred) or pin-value=<PIN>." >&2
                echo "       Current: ${IOTGW_RAUC_STREAMING_TLS_KEY}" >&2
                exit 1
                ;;
        esac
    fi

    install -d ${D}${sysconfdir}/rauc
    # Render system.conf from template using bundle-compatible
    sed -e "s|@COMPATIBLE@|${RAUC_BUNDLE_COMPATIBLE}|g" \
        -e "s|@TLS_KEY@|${IOTGW_RAUC_STREAMING_TLS_KEY}|g" \
        ${WORKDIR}/iotgw-system.conf > ${D}${sysconfdir}/rauc/system.conf

    if [ "${IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
        if [ -z "${IOTGW_RAUC_ENCRYPTION_KEY}" ]; then
            echo "ERROR: IOTGW_RAUC_ENCRYPTION_KEY is required when encrypted bundle mode is enabled." >&2
            exit 1
        fi
        {
            echo ""
            echo "[encryption]"
            echo "key=${IOTGW_RAUC_ENCRYPTION_KEY}"
            if [ -n "${IOTGW_RAUC_ENCRYPTION_CERT}" ]; then
                echo "cert=${IOTGW_RAUC_ENCRYPTION_CERT}"
            fi
        } >> ${D}${sysconfdir}/rauc/system.conf
    fi
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
RDEPENDS:${PN} += "ota-certs iotgw-ota-user"
