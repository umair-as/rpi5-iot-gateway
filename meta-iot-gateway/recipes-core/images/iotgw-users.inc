# Central users/groups for IoT GW images (applied via extrausers in image recipe)

# Default password hashes (override in local.conf or kas/local.yml).
# Note: weston user and groups are managed by upstream weston-init.
IOTGW_ROOT_PASSWORD_HASH ?= "\$6\$sWWOE4/u3camnX97\$u7vb8jM/kUyAIhx/Xvx7.X0EaAKuz6TLIXNZurRYbKQL16xdA.qtbWj33aoZihHdojt1HxfKi2GHuBuceOzWQ/"
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
"
