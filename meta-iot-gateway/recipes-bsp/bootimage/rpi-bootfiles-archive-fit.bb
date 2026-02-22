SUMMARY = "Boot files archive (FIT variant) for RAUC post-install copy"
DESCRIPTION = "Packs bootloader and FIT kernel boot files into bootfiles-fit.tar.gz for inclusion in RAUC bundles."
require rpi-bootfiles-archive-common.inc

IOTGW_BOOTFILES_ARCHIVE_NAME = "bootfiles-fit.tar.gz"
IOTGW_BOOTFILES_STAGE_FILES = "boot.scr u-boot.bin config.txt cmdline.txt splash.bmp fitImage Image kernel_2712.img"
