FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Optional U-Boot source override for bring-up testing.
# Set these in kas/local.yml (or a dedicated kas include) when needed:
#   IOTGW_UBOOT_ALT_URI = "git://source.denx.de/u-boot/u-boot.git;protocol=https;branch=master"
#   IOTGW_UBOOT_ALT_SRCREV = "<pinned-commit>"
IOTGW_UBOOT_ALT_URI ?= ""
IOTGW_UBOOT_ALT_SRCREV ?= ""

python () {
    alt_uri = (d.getVar("IOTGW_UBOOT_ALT_URI") or "").strip()
    alt_srcrev = (d.getVar("IOTGW_UBOOT_ALT_SRCREV") or "").strip()
    if alt_uri:
        d.setVar("SRC_URI", alt_uri)
    if alt_srcrev:
        d.setVar("SRCREV", alt_srcrev)
}

# Add IoT GW hardening and RAUC-friendly settings via Kconfig fragment
SRC_URI:append = " file://iotgw-uboot.cfg file://fw_env.config"
SRC_URI:append = "${@' file://iotgw-uboot-tpm.cfg' if d.getVar('IOTGW_ENABLE_TPM_SLB9672') == '1' else ''}"

# Keep boot delay minimal; allow keyed interrupt only
# Note: Further hardening (FIT signatures) will be added separately per-prod build

do_install:append() {
    # Override fw_env.config from lower-priority layers.
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}
