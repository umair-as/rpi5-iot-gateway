FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Every image: no setuid-root busybox. The applets it carried are provided by
# shadow, util-linux and iputils.
# IOTGW_BUSYBOX_TRIM_NET (every image unless set to 0): also drop the network
# clients and servers, and the daemons journald, udev and networkd replace.
# wget comes from GNU wget where an image wants it.
IOTGW_BUSYBOX_TRIM_NET ?= "1"
# With no setuid applets left there is nothing to split out, and the split path
# in oe-core requires a busybox.links.suid file at packaging time.
BUSYBOX_SPLIT_SUID = "0"
# Without syslogd the recipe installs no busybox-syslog.service, and systemd.bbclass
# fails on a package that names a missing unit.
SYSTEMD_PACKAGES = "${@'' if bb.utils.to_boolean(d.getVar('IOTGW_BUSYBOX_TRIM_NET')) else d.expand('${PN}-syslog')}"
SRC_URI:append = " file://iotgw-no-suid-applets.cfg"
SRC_URI:append = "${@' file://iotgw-no-net-applets.cfg' if bb.utils.to_boolean(d.getVar('IOTGW_BUSYBOX_TRIM_NET')) else ''}"
