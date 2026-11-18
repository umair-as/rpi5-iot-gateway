SUMMARY = "IoT GW SELinux MAC userspace"
DESCRIPTION = "SELinux userspace and policy for the active MAC: \
packagegroup-core-selinux (libselinux/libsemanage/libsepol, policycoreutils, \
setools, semodule-utils), the MCS reference policy (refpolicy-mcs) with the \
iotgw project module, and the /data relabel unit (iotgw-selinux-relabel). The \
meta-selinux first-boot autorelabel unit arrives through packagegroup-core-selinux \
(hard RDEPENDS there) and is MASKED at rootfs time (iotgw-rootfs.bbclass): the root is \
labelled at build time and /.autorelabel cannot exist on the dm-verity root, so the \
unit is inert. Pulled into every image \
via iot-gw-image-base.inc. See docs/SELINUX.md."
LICENSE = "MIT"

inherit packagegroup

# refpolicy-mcs is the concrete provider selected by
# PREFERRED_PROVIDER_virtual/refpolicy in iotgw-common.inc; naming it here
# (not virtual/refpolicy) keeps the image from pulling a second variant.
RDEPENDS:${PN} = " \
    packagegroup-core-selinux \
    refpolicy-mcs \
    iotgw-selinux-relabel \
"
