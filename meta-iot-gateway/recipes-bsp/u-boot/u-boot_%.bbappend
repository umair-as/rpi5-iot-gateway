FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Add IoT GW hardening and RAUC-friendly settings via Kconfig fragment
SRC_URI:append = " file://iotgw-uboot.cfg"

# Keep boot delay minimal; allow keyed interrupt only
# Note: Further hardening (FIT signatures) will be added separately per-prod build
