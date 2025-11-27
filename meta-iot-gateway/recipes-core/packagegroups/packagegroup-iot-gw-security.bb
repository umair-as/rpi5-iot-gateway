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
"

# Optional: Add these for enhanced security monitoring
# RRECOMMENDS:${PN} = " \
#     aide \
#     tripwire \
# "
