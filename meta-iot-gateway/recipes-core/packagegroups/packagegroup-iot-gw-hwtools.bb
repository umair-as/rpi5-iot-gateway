SUMMARY = "IoT GW Hardware tools and kernel modules"
DESCRIPTION = "GPIO/I2C/SPI tools and kernel-modules for Raspberry Pi gateway hardware access."
LICENSE = "MIT"

inherit packagegroup

# Not allarch: includes kernel-modules and arch-specific tool package names
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = " \
    kernel-modules \
    i2c-tools \
    spitools \
    spidev-test \
    libgpiod-tools \
    raspi-gpio \
    ${@bb.utils.contains('IOTGW_ENABLE_RPI_EEPROM', '1', 'rpi-eeprom iotgw-rpi-eeprom', '', d)} \
"
