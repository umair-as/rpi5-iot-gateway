# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check wrong-product matches.
#
# CVE-2025-64170 / CVE-2025-64517 affect the separate Rust sudo-rs
# implementation, not the classic C sudo 1.9.17p2 shipped here.
#   https://nvd.nist.gov/vuln/detail/CVE-2025-64170
#   https://nvd.nist.gov/vuln/detail/CVE-2025-64517
CVE_STATUS[CVE-2025-64170] = "cpe-incorrect: affects the Rust sudo-rs, not classic C sudo (shipped)"
CVE_STATUS[CVE-2025-64517] = "cpe-incorrect: affects the Rust sudo-rs, not classic C sudo (shipped)"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Admin elevation lands in sysadm_t (SELinux ROLE/TYPE), see the file. sudo
# itself is built with SELinux by meta-selinux (enable-selinux) and with PAM
# whenever the pam distro feature is on.
SRC_URI:append:class-target = " file://10-iotgw-admin-selinux"

do_install:append:class-target() {
    install -d -m 0750 ${D}${sysconfdir}/sudoers.d
    install -m 0440 ${UNPACKDIR}/10-iotgw-admin-selinux \
        ${D}${sysconfdir}/sudoers.d/10-iotgw-admin-selinux
    # root gets no sudo rule. sudo does not authenticate a caller that is
    # already root, so a root SSH login (staff_t) could otherwise reach
    # sysadm_t with no password through the admin ROLE/TYPE path; root steps
    # up with newrole, which always asks for the password.
    sed -i '/^root[[:space:]]\+ALL[[:space:]]*=/d' ${D}${sysconfdir}/sudoers
    if grep -q '^root[[:space:]]' ${D}${sysconfdir}/sudoers; then
        bbfatal "sudoers still grants root a rule; root must elevate with newrole"
    fi
}

