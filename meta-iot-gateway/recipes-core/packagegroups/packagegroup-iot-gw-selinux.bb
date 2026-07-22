SUMMARY = "IoT GW SELinux MAC userspace"
DESCRIPTION = "SELinux userspace and policy for the active MAC: \
packagegroup-core-selinux (libselinux/libsemanage/libsepol, policycoreutils, \
setools, semodule-utils), the MCS reference policy (refpolicy-mcs), and the \
first-boot autorelabel unit (selinux-autorelabel). Pulled into every image \
via iot-gw-image-base.inc. See docs/SELINUX.md."
LICENSE = "MIT"

inherit packagegroup

# refpolicy-mcs is the concrete provider selected by
# PREFERRED_PROVIDER_virtual/refpolicy in iotgw-common.inc; naming it here
# (not virtual/refpolicy) keeps the image from pulling a second variant.
RDEPENDS:${PN} = " \
    packagegroup-core-selinux \
    refpolicy-mcs \
    selinux-autorelabel \
"
