SUMMARY = "Install developer SSH authorized_keys for root and devel (dev builds only)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Optional: set in local.conf or KAS overlay to point to host files
# IOTGW_DEV_ROOT_AUTH_KEYS_FILE = "/path/to/root_authorized_keys"
# IOTGW_DEV_DEVEL_AUTH_KEYS_FILE = "/path/to/devel_authorized_keys"
IOTGW_DEV_ROOT_AUTH_KEYS_FILE ?= ""
IOTGW_DEV_DEVEL_AUTH_KEYS_FILE ?= ""

S = "${WORKDIR}"

# Produce a package even if no keys are provided, so the image build
# (DNF install) never fails on missing package.
ALLOW_EMPTY:${PN} = "1"

do_install() {
    # Root keys (optional)
    if [ -n "${IOTGW_DEV_ROOT_AUTH_KEYS_FILE}" ] && [ -f "${IOTGW_DEV_ROOT_AUTH_KEYS_FILE}" ]; then
        install -d -m 0700 ${D}/root/.ssh
        install -m 0600 "${IOTGW_DEV_ROOT_AUTH_KEYS_FILE}" ${D}/root/.ssh/authorized_keys
    fi

    # Devel keys (optional)
    if [ -n "${IOTGW_DEV_DEVEL_AUTH_KEYS_FILE}" ] && [ -f "${IOTGW_DEV_DEVEL_AUTH_KEYS_FILE}" ]; then
        install -d -m 0700 ${D}/home/devel/.ssh
        install -m 0600 "${IOTGW_DEV_DEVEL_AUTH_KEYS_FILE}" ${D}/home/devel/.ssh/authorized_keys
        # Ownership of /home/devel is normalized in iotgw-rauc-image.bbclass
    fi
}

FILES:${PN} += " /root/.ssh/authorized_keys /home/devel/.ssh/authorized_keys "

RDEPENDS:${PN} = " openssh "
