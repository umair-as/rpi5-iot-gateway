FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Replace the default bootscript with our customized one (banner + optional splash)
SRC_URI:append = " file://boot.cmd.in"

