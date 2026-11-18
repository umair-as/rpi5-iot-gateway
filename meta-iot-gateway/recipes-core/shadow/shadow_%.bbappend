# CVE_STATUS — CVE-2016-15024 refers to the unrelated doomsider/shadow project,
# not the Linux shadow-utils suite shipped here (wrong-CPE match).
# https://nvd.nist.gov/vuln/detail/CVE-2016-15024
CVE_STATUS[CVE-2016-15024] = "cpe-incorrect: refers to the doomsider/shadow project, not shadow-utils"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Console login PAM stack (pam_selinux close/open in Fedora's order, plus
# pam_loginuid, which neither OE-Core's nor meta-selinux's login stack has).
SRC_URI:append = " file://iotgw-pam-login"

# Harden /etc/login.defs at package build time so values survive RAUC OTA updates.
# shadow-utils does not support login.defs.d/ include directories, so patching
# must happen here rather than via a drop-in fragment.

do_install:append() {
    defs="${D}${sysconfdir}/login.defs"
    [ -f "$defs" ] || return 0

    # Password aging (AUTH-9286)
    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t90/'  "$defs"
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t7/'   "$defs"
    sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t14/'  "$defs"

    # Restrictive umask (AUTH-9328)
    sed -i 's/^UMASK.*/UMASK\t\t027/'               "$defs"

    # SHA-crypt rounds (AUTH-9230)
    grep -q '^SHA_CRYPT_MIN_ROUNDS' "$defs" \
        && sed -i 's/^SHA_CRYPT_MIN_ROUNDS.*/SHA_CRYPT_MIN_ROUNDS 5000/'  "$defs" \
        || echo 'SHA_CRYPT_MIN_ROUNDS 5000'  >> "$defs"
    grep -q '^SHA_CRYPT_MAX_ROUNDS' "$defs" \
        && sed -i 's/^SHA_CRYPT_MAX_ROUNDS.*/SHA_CRYPT_MAX_ROUNDS 10000/' "$defs" \
        || echo 'SHA_CRYPT_MAX_ROUNDS 10000' >> "$defs"

    # Ensure SHA512 is the hash algorithm
    grep -q '^ENCRYPT_METHOD' "$defs" \
        && sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' "$defs" \
        || echo 'ENCRYPT_METHOD SHA512' >> "$defs"
}

do_install:append:class-target() {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'pam', 'true', 'false', d)}; then
        install -m 0644 ${UNPACKDIR}/iotgw-pam-login ${D}${sysconfdir}/pam.d/login
    fi
}

# Every module named in iotgw-pam-login that shadow's PAM_PLUGINS does not
# already pull: a "required" module that is not installed refuses the login,
# and the serial console is the recovery path.
RDEPENDS:${PN}-base:append:class-target = " ${@bb.utils.contains('DISTRO_FEATURES', 'pam', \
    'pam-plugin-loginuid pam-plugin-keyinit pam-plugin-unix', '', d)} \
    ${@bb.utils.contains('DISTRO_FEATURES', 'pam selinux', 'pam-plugin-selinux', '', d)}"
