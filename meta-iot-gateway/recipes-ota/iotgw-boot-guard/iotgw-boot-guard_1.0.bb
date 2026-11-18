SUMMARY = "Guards for the shared Raspberry Pi 5 /boot: RAUC pre-install handler and boot-file updater"
DESCRIPTION = "iotgw-boot-guard: the RAUC system pre-install handler that refuses a \
bundle which cannot deliver and install the target slot's signed FIT, and the FIT \
trust-anchor checks it shares with the updater. \
iotgw-boot-guard-bootfiles-update: the operator-run updater for U-Boot \
(kernel_2712.img), the board DTB (FIT trust anchor) and config.txt on the single-copy /boot, with the staged files, \
backup and --restore. RAUC installs never write those files."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "raspberrypi5"
PACKAGE_ARCH = "${MACHINE_ARCH}"

SRC_URI = " \
    file://iotgw-fit-anchor.sh \
    file://iotgw-rauc-preinstall \
    file://iotgw-rpi-bootfiles-update.sh \
"
S = "${UNPACKDIR}"

# The staged boot files are the deploy artifacts the WIC places on /boot: the
# board DTB with the FIT public keys injected by the kernel's do_deploy,
# config.txt, and u-boot.bin installed as kernel_2712.img (IMAGE_BOOT_FILES
# "u-boot.bin;kernel_2712.img"), the firmware's default kernel.
do_install[depends] += "virtual/kernel:do_deploy u-boot:do_deploy rpi-bootfiles:do_deploy rpi-config:do_deploy"
do_install[vardeps] += "BOOTFILES_DIR_NAME"

do_install() {
    install -d ${D}${libdir}/iotgw ${D}${libexecdir}/iotgw ${D}${sbindir}
    install -m 0644 ${UNPACKDIR}/iotgw-fit-anchor.sh ${D}${libdir}/iotgw/iotgw-fit-anchor.sh
    install -m 0755 ${UNPACKDIR}/iotgw-rauc-preinstall ${D}${libexecdir}/iotgw/iotgw-rauc-preinstall
    install -m 0755 ${UNPACKDIR}/iotgw-rpi-bootfiles-update.sh ${D}${sbindir}/iotgw-rpi-bootfiles-update

    stage=${D}${datadir}/iotgw/rpi-boot
    install -d ${stage}
    manifest=${stage}/manifest.tsv
    printf 'artifact\tsha256\tsize\tboot_target\n' > ${manifest}
    # $1 source in DEPLOY_DIR_IMAGE (symlinks followed), $2 name on /boot.
    collect() {
        [ -f "$1" ] || bbfatal "iotgw-boot-guard: deploy artifact not found: $1"
        install -m 0644 "$1" ${stage}/"$2"
        printf '%s\t%s\t%s\t%s\n' "$2" "$(sha256sum ${stage}/"$2" | awk '{print $1}')" \
            "$(stat -c%s ${stage}/"$2")" "$2" >> ${manifest}
    }
    collect ${DEPLOY_DIR_IMAGE}/${BOOTFILES_DIR_NAME}/config.txt config.txt
    collect ${DEPLOY_DIR_IMAGE}/bcm2712-rpi-5-b.dtb bcm2712-rpi-5-b.dtb
    collect ${DEPLOY_DIR_IMAGE}/u-boot.bin kernel_2712.img
}

PACKAGES =+ "${PN}-bootfiles-update"
FILES:${PN} = "${libdir}/iotgw/iotgw-fit-anchor.sh ${libexecdir}/iotgw/iotgw-rauc-preinstall"
FILES:${PN}-bootfiles-update = "${sbindir}/iotgw-rpi-bootfiles-update ${datadir}/iotgw/rpi-boot"
RDEPENDS:${PN} = "bash dtc coreutils gawk"
RDEPENDS:${PN}-bootfiles-update = "${PN} bash coreutils util-linux-findmnt gawk"
