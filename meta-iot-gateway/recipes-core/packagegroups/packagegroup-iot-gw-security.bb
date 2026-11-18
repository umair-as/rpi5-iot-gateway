SUMMARY = "IoT GW Security Hardening package group"
DESCRIPTION = "Security hardening packages based on Lynis audit recommendations. \
Installed by every image tier (iot-gw-image-base.inc), not per tier."
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    iotgw-hardening \
    iotgw-audit \
    audit \
    auditd \
    ${@bb.utils.contains('IOTGW_ENABLE_IMA', '1', 'ima-evm-utils ima-inspect ima-policy', '', d)} \
"
