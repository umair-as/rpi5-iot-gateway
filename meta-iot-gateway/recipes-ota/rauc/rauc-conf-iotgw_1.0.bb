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

# Bundle-signing PKI chain hygiene.
# IOTGW_RAUC_KEYRING_CERTS: space-separated list of cert files installed
#   into /etc/rauc/keyring.d/ and hashed via `openssl rehash`. When set, the
#   [keyring] stanza renders as `directory=/etc/rauc/keyring.d/` so multiple
#   trust anchors can be enumerated (e.g. dual-Root keyring or a transition
#   window with legacy + new certs). When empty, the legacy single-cert form
#   (path=/etc/rauc/ca.cert.pem) is used and the cert comes from
#   RAUC_DEVICE_KEYRING / RAUC_CERT_FILE.
# IOTGW_RAUC_ALLOWED_SIGNER_CNS: semicolon-separated CN allowlist. Empty = no
#   restriction (dev). Set on prod images to fence off legacy / dev leaves.
# IOTGW_RAUC_CHECK_PURPOSE: OpenSSL X.509 purpose enforced on the bundle signer
#   chain (e.g. "codesign"). Empty disables the purpose check — required during
#   the migration window when legacy signer certs do not carry an explicit
#   codeSigning EKU. Enable at cutover when every signing leaf is chain-issued
#   from a CA template that sets extendedKeyUsage = codeSigning.
IOTGW_RAUC_KEYRING_CERTS ?= ""
IOTGW_RAUC_ALLOWED_SIGNER_CNS ?= ""
IOTGW_RAUC_CHECK_PURPOSE ?= ""

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

    # Keyring locator: directory mode when IOTGW_RAUC_KEYRING_CERTS is set,
    # else legacy single-cert path mode. Steady state for prod is directory.
    if [ -n "${IOTGW_RAUC_KEYRING_CERTS}" ]; then
        sed -i "s|@RAUC_KEYRING_LOCATOR@|directory=/etc/rauc/keyring.d/|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "s|@RAUC_KEYRING_LOCATOR@|path=/etc/rauc/ca.cert.pem|g" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    # check-purpose: render only when non-empty; otherwise drop the token line.
    # Empty default avoids breaking the migration window (legacy single-cert
    # keyrings whose signer cert has no codeSigning EKU).
    if [ -n "${IOTGW_RAUC_CHECK_PURPOSE}" ]; then
        sed -i "s|@RAUC_CHECK_PURPOSE_STANZA@|check-purpose=${IOTGW_RAUC_CHECK_PURPOSE}|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "/@RAUC_CHECK_PURPOSE_STANZA@/d" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    # allowed-signer-cns: render only when non-empty; otherwise drop the token line.
    if [ -n "${IOTGW_RAUC_ALLOWED_SIGNER_CNS}" ]; then
        sed -i "s|@RAUC_ALLOWED_SIGNER_CNS_STANZA@|allowed-signer-cns=${IOTGW_RAUC_ALLOWED_SIGNER_CNS}|g" \
            ${D}${sysconfdir}/rauc/system.conf
    else
        sed -i "/@RAUC_ALLOWED_SIGNER_CNS_STANZA@/d" \
            ${D}${sysconfdir}/rauc/system.conf
    fi

    if [ "${IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
        if [ -z "${IOTGW_RAUC_ENCRYPTION_KEY}" ]; then
            bbfatal "IOTGW_RAUC_ENCRYPTION_KEY is required when encrypted bundle mode is enabled."
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

    # Device keyring deployment.
    # Directory mode: install each cert from IOTGW_RAUC_KEYRING_CERTS into
    # /etc/rauc/keyring.d/ and produce OpenSSL hash-dir entries via `openssl rehash`.
    # Path mode: install a single cert as /etc/rauc/ca.cert.pem (legacy / M1).
    if [ -n "${IOTGW_RAUC_KEYRING_CERTS}" ]; then
        install -d ${D}${sysconfdir}/rauc/keyring.d
        for cert in ${IOTGW_RAUC_KEYRING_CERTS}; do
            if [ ! -f "$cert" ]; then
                bbfatal "Keyring directory entry not found: $cert"
            fi
            install -m 0644 "$cert" ${D}${sysconfdir}/rauc/keyring.d/
        done
        if ! command -v openssl >/dev/null 2>&1; then
            bbfatal "openssl required on the build host to rehash /etc/rauc/keyring.d/."
        fi
        openssl rehash ${D}${sysconfdir}/rauc/keyring.d/ >/dev/null
    else
        # Prefer RAUC_DEVICE_KEYRING; fallback to RAUC_CERT_FILE (dev setups often reuse it).
        keyring="${RAUC_DEVICE_KEYRING}"
        if [ -z "$keyring" ]; then
            keyring="${RAUC_CERT_FILE}"
        fi
        if [ -z "$keyring" ]; then
            bbfatal "Neither RAUC_DEVICE_KEYRING nor RAUC_CERT_FILE is set. Configure in kas/local.yml."
        fi
        if [ ! -f "$keyring" ]; then
            bbfatal "Keyring file not found: $keyring"
        fi
        install -m 0644 "$keyring" ${D}${sysconfdir}/rauc/ca.cert.pem
    fi
}

FILES:${PN} = "${sysconfdir}/rauc/system.conf \
               ${sysconfdir}/rauc/ca.cert.pem \
               ${sysconfdir}/rauc/keyring.d \
               ${sysconfdir}/rauc/keyring.d/*"

# ota-certs provisions the streaming TLS certificates referenced in system.conf
RDEPENDS:${PN} += "ota-certs iotgw-ota-user"
