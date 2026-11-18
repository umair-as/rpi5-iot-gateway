# The two gpio PROGRAM rules chgrp/chmod the legacy sysfs GPIO interface
# (/sys/class/gpio and each gpiochip's sysfs directory). This kernel builds
# without CONFIG_GPIO_SYSFS: GPIO is the character device only, whose group
# the plain SUBSYSTEM=="gpio" GROUP= rule in the same file already sets. The
# PROGRAM rules then change nothing a user can reach and cost udev_t a sysfs
# setattr on every gpiochip add, which SELinux denies. The PWM rule stays: the
# sysfs PWM interface is still how PWM is used.
do_install:append() {
    sed -i '/^SUBSYSTEM=="gpio".*PROGRAM=/d' ${D}${sysconfdir}/udev/rules.d/99-com.rules
    if grep -q '^SUBSYSTEM=="gpio".*PROGRAM=' ${D}${sysconfdir}/udev/rules.d/99-com.rules; then
        bbfatal "99-com.rules: sysfs GPIO PROGRAM rules still present"
    fi
    grep -q '^SUBSYSTEM=="gpio", GROUP="gpio"' ${D}${sysconfdir}/udev/rules.d/99-com.rules || \
        bbfatal "99-com.rules: the gpiochip GROUP rule is gone; review this bbappend"
}
