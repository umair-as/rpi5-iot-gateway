SUMMARY = "Boot files archive for RAUC post-install copy"
DESCRIPTION = "Packs bootloader and kernel boot files from the image deploy directory into bootfiles.tar.gz for inclusion in RAUC bundles. Includes boot.scr, u-boot.bin, kernel Image, kernel_2712.img, DTBs, overlays, and optional splash.bmp."
require rpi-bootfiles-archive-common.inc

IOTGW_BOOTFILES_ARCHIVE_NAME = "bootfiles.tar.gz"
IOTGW_BOOTFILES_STAGE_FILES = "boot.scr u-boot.bin config.txt cmdline.txt splash.bmp Image kernel_2712.img"
