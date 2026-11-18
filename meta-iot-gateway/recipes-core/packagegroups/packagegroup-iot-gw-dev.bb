SUMMARY = "IoT GW Development package group"
DESCRIPTION = "Developer tooling layered on top of base/apps"
LICENSE = "MIT"

inherit packagegroup

# mosquitto: a deliberate MQTT test broker on dev and desktop, loopback only
# (mosquitto.conf) and confined (iotgw_mosquitto_t). listen-allowlist.txt
# admits it on those images only; the prod hygiene gate keeps it out of prod.
RDEPENDS:${PN} = " \
    nmap \
    iperf3 \
    packagegroup-iot-gw-devtools \
    packagegroup-core-buildessential \
    gdb \
    gdbserver \
    ltrace \
    valgrind \
    perf \
    wireshark \
    htop \
    kernel-hardening-checker \
    ota-certs-devca \
    ota-updater \
    mosquitto \
    mosquitto-clients \
    ${@bb.utils.contains('IOTGW_RAUC_STREAMING_KEY_MODE_EFFECTIVE','pkcs11',' opensc','',d)} \
    ${@bb.utils.contains('IOTGW_RAUC_PKCS11_USES_TPM2','1',' tpm2-pkcs11-tools','',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672','1',' tpm2-tools tpm2-tss','',d)} \
    ${@bb.utils.contains('IOTGW_ENABLE_TPM_SLB9672','1',bb.utils.contains('IOTGW_ENABLE_TPM_CRYPTO_PROVIDERS','1',' tpm2-pkcs11 tpm2-openssl tpm2-tss-engine','',d),'',d)} \
"

RDEPENDS:${PN}:append = "${@bb.utils.contains('IOTGW_ENABLE_OTBR','1',' iotgw-otbrctl','',d)}"
