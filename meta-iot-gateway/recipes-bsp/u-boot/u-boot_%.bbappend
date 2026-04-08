FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Add IoT GW hardening and RAUC-friendly settings via Kconfig fragment
SRC_URI:append = " file://iotgw-uboot.cfg file://fw_env.config file://0001-rpi-env-minimize-boot-scanning-for-iot-gateway.patch file://0002-rpi-iotgw-appliance-fast-path-and-netboot-gate.patch"

# Keep boot delay minimal; allow keyed interrupt only
# Note: Further hardening (FIT signatures) will be added separately per-prod build

do_install:append() {
    # Override fw_env.config from lower-priority layers.
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}
