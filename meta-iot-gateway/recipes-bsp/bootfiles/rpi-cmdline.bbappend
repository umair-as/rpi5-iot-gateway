# Ensure firmware-provided /chosen/bootargs uses the gateway serial console.
# U-Boot inherits these args and appends RAUC slot root=PARTUUID at runtime.
CMDLINE_SERIAL = "console=ttyAMA10,115200"

# Avoid embedding a static root= token from firmware cmdline.
# RAUC/U-Boot chooses the active slot and injects root=PARTUUID dynamically.
CMDLINE_ROOTFS = ""

# Crash-debug lab profile (opt-in via IOTGW_ENABLE_CRASH_DEBUG_DEV=1):
# - reserved-memory/ramoops is provided by a kernel DT patch
# - keep panic/oops/sysrq behavior deterministic for lab crash testing
CMDLINE:append = "${@bb.utils.contains('IOTGW_ENABLE_CRASH_DEBUG_DEV', '1', ' panic=10 oops=panic sysrq_always_enabled=1', '', d)}"
