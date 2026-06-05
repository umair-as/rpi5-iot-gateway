SUMMARY = "IoT GW Security Hardening package group"
DESCRIPTION = "Security hardening packages based on Lynis audit recommendations. \
Include this packagegroup in hardened/production images."
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    iotgw-hardening \
    iotgw-audit \
    audit \
    auditd \
    ${@bb.utils.contains('IOTGW_ENABLE_IMA', '1', 'ima-evm-utils ima-inspect ima-policy', '', d)} \
"
