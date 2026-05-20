# Upstream u-boot-tools builds fdt_add_pubkey as part of `make cross_tools`
# but only installs mkimage, mkenvimage, dumpimage, and fit_check_sign.
#
# We need fdt_add_pubkey at ${STAGING_BINDIR_NATIVE}/fdt_add_pubkey for the
# FIT DTB key-rotation step in linux-iotgw-mainline-fit_6.18.bb, which adds
# a YubiKey-resident public certificate to the runtime control FDT without
# requiring the corresponding private key on the build host.

do_install:append() {
    install -m 0755 tools/fdt_add_pubkey ${D}${bindir}/uboot-fdt_add_pubkey
    ln -sf uboot-fdt_add_pubkey ${D}${bindir}/fdt_add_pubkey
}

FILES:${PN}-mkimage += "${bindir}/uboot-fdt_add_pubkey ${bindir}/fdt_add_pubkey"
