# Developer user/group definitions for dev and desktop image variants only.
# Not included by iot-gw-image-base.inc; included explicitly by
# iot-gw-image-dev.bb and iot-gw-image-desktop.bb.

IOTGW_DEVEL_PASSWORD_HASH ?= "\$6\$BsSCxm5lOvmpudgE\$PyqVXB5o/rdS7R396ETDL/roIra.rlCfYHf50hv5A/MHjsJ2SYffCjiOMMnTs2BoXkSMZmG6/AsZcso.AorMJ0"
EXTRA_USERS_PARAMS:append = " \
    useradd -K PASS_MAX_DAYS=99999 -d /home/devel -m -s /bin/bash -G sudo,dialout,netdev,plugdev,video,render,input,wireshark,podman,gpio,i2c,spi devel; \
    usermod -p '${IOTGW_DEVEL_PASSWORD_HASH}' devel; \
"

# Desktop profile: add wayland group membership for devel (Weston/Wayland)
EXTRA_USERS_PARAMS:append:desktop = " \
    groupadd -f -r wayland; \
    usermod -a -G wayland devel; \
"
