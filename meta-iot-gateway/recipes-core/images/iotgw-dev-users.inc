# Developer user/group definitions for dev and desktop image variants only.
# Not included by iot-gw-image-base.inc; included explicitly by
# iot-gw-image-dev.bb and iot-gw-image-desktop.bb.

# No password by default (see iotgw-users.inc); the bench console password
# comes from kas/local.yml. SSH is key-only, so devel's key login and its sudo
# path do not depend on a password.
IOTGW_DEVEL_PASSWORD_HASH ?= "*"
# Primary group first: useradd-staticids rewrites this useradd to --gid 1000
# from the distro tables, and useradd creates no group when given one.
EXTRA_USERS_PARAMS:append = " \
    groupadd -f -g 1000 devel; \
    useradd -u 1000 -g 1000 -K PASS_MAX_DAYS=99999 -d /home/devel -m -s /bin/bash -G sudo,dialout,netdev,plugdev,video,render,input,wireshark,podman,gpio,i2c,spi devel; \
    usermod -p '${@iotgw_password_field(d, 'IOTGW_DEVEL_PASSWORD_HASH')}' devel; \
"

# Desktop profile: add wayland group membership for devel (Weston/Wayland)
EXTRA_USERS_PARAMS:append:desktop = " \
    groupadd -f -g 975 wayland; \
    usermod -a -G wayland devel; \
"
