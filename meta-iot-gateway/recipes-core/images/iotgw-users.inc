# Central users/groups for IoT GW images (applied via extrausers in image recipe)

# Default password hashes (override in local.conf or kas/local.yml).
# Note: weston user and groups are managed by upstream weston-init.
IOTGW_ROOT_PASSWORD_HASH ?= "\$6\$sWWOE4/u3camnX97\$u7vb8jM/kUyAIhx/Xvx7.X0EaAKuz6TLIXNZurRYbKQL16xdA.qtbWj33aoZihHdojt1HxfKi2GHuBuceOzWQ/"
IOTGW_DEVEL_PASSWORD_HASH ?= "\$6\$BsSCxm5lOvmpudgE\$PyqVXB5o/rdS7R396ETDL/roIra.rlCfYHf50hv5A/MHjsJ2SYffCjiOMMnTs2BoXkSMZmG6/AsZcso.AorMJ0"
EXTRA_USERS_PARAMS:append = " \
    usermod -p '${IOTGW_ROOT_PASSWORD_HASH}' root; \
    groupadd -f -r sudo; \
    groupadd -f -r netdev; \
    groupadd -f -r wireshark; \
    groupadd -f -r podman; \
    groupadd -f -r gpio; \
    groupadd -f -r i2c; \
    groupadd -f -r spi; \
    groupadd -f -r ota; \
    groupadd -f -r systemd-timesync; \
    useradd -r -g systemd-timesync -d / -s /sbin/nologin systemd-timesync; \
    useradd -K PASS_MAX_DAYS=99999 -d /home/devel -m -s /bin/bash -G sudo,dialout,netdev,plugdev,video,render,input,wireshark,podman,gpio,i2c,spi devel; \
    usermod -p '${IOTGW_DEVEL_PASSWORD_HASH}' devel; \
"

# Desktop profile: add wayland group membership for devel (Weston/Wayland)
EXTRA_USERS_PARAMS:append:desktop = " \
    groupadd -f -r wayland; \
    usermod -a -G wayland devel; \
"
