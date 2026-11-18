# Boot every image tier through iotgw-preinit (recipes-support/iotgw-preinit).
#
# The pre-init assembles /data, the SELinux policy and the writable /etc,
# /root, /home before PID 1, as kernel_t, so the overlay mounts are not checked
# against a confined mounter domain and /etc is never a persistent overlay that
# could hide newer shipped files after an OTA. State that persists is an explicit list of binds (docs/PERSISTENT_STATE.md).

IMAGE_INSTALL:append = " iotgw-preinit"

# Goes into /chosen/bootargs of both signed slot FITs (iotgw-verity-image.bbclass).
IOTGW_VERITY_KERNEL_ARGS:append = " init=${base_sbindir}/iotgw-preinit"
