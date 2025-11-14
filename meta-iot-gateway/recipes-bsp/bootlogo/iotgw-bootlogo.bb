SUMMARY = "IoT Gateway U-Boot splash logo"
DESCRIPTION = "Installs a pre-rendered 24-bit BMP splash (splash.bmp) for U-Boot. Convert your PNG externally and place splash.bmp in files/."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch deploy

S = "${WORKDIR}"

SRC_URI = "file://meshiot-logo.bmp"

do_install() {
    install -d ${D}/boot
    install -m 0644 ${WORKDIR}/meshiot-logo.bmp ${D}/boot/splash.bmp
}

FILES:${PN} = "/boot/splash.bmp"

# Make splash.bmp available in DEPLOY_DIR_IMAGE so boot.vfat assembly can pick it up
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${WORKDIR}/meshiot-logo.bmp ${DEPLOYDIR}/splash.bmp
}

addtask deploy after do_install before do_build
