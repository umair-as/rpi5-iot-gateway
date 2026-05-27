# Ensure firmware-provided /chosen/bootargs uses the gateway serial console.
# U-Boot inherits these args and appends RAUC slot root=PARTUUID at runtime.
CMDLINE_SERIAL = "console=ttyAMA10,115200"

# Avoid embedding a static root= token from firmware cmdline.
# RAUC/U-Boot chooses the active slot and injects root=PARTUUID dynamically.
CMDLINE_ROOTFS = ""
