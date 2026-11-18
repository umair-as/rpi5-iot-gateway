# Carried in this layer ahead of the layer pin: copied from meta-openembedded wrynose; the
# CVE_STATUS block is re-derived from the libssh advisories and CHANGELOG.
# Remove at the next joint pin move, once the pinned layer ships this
# version or newer.

SUMMARY = "Multiplatform C library implementing the SSHv2 and SSHv1 protocol"
HOMEPAGE = "http://www.libssh.org"
SECTION = "libs"
LICENSE = "LGPL-2.1-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=dabb4958b830e5df11d2b0ed8ea255a0"

DEPENDS = "zlib openssl"

SRC_URI = "git://gitlab.com/libssh/libssh-mirror.git;protocol=https;branch=stable-0.11;tag=${BPN}-${PV} \
           file://0001-tests-CMakeLists.txt-do-not-search-ssh-sshd-commands.patch \
           file://run-ptest \
          "

SRC_URI:append:toolchain-clang = " file://0001-CompilerChecks.cmake-drop-Wunused-variable-flag.patch"

SRCREV = "a09fdd00416e53b6ed436df6ff14339a4f884601"

CVE_PRODUCT = "libssh:libssh"

inherit cmake ptest

PACKAGECONFIG ??= "gcrypt ${@bb.utils.contains('PTEST_ENABLED', '1', 'tests', '', d)}"
PACKAGECONFIG[gssapi] = "-DWITH_GSSAPI=1, -DWITH_GSSAPI=0, krb5, "
PACKAGECONFIG[gcrypt] = "-DWITH_GCRYPT=1, -DWITH_GCRYPT=0, libgcrypt, "
PACKAGECONFIG[tests] = "-DUNIT_TESTING=1, -DUNIT_TESTING=0, cmocka"

ARM_INSTRUCTION_SET:armv5 = "arm"

EXTRA_OECMAKE = " \
    -DWITH_PCAP=1 \
    -DWITH_SFTP=1 \
    -DWITH_ZLIB=1 \
    -DWITH_EXAMPLES=0 \
    "

do_compile:prepend () {
    if [ ${PTEST_ENABLED} = "1" ]; then
        sed -i -e 's|${B}|${PTEST_PATH}|g' ${B}/config.h
        sed -i -e 's|${S}|${PTEST_PATH}|g' ${B}/config.h
    fi
}

do_install_ptest () {
    install -d ${D}${PTEST_PATH}/tests
    cp -f ${B}/tests/unittests/torture_* ${D}${PTEST_PATH}/tests/
    install -d ${D}${PTEST_PATH}/tests/unittests
    cp -f ${S}/tests/unittests/hello*.sh ${D}${PTEST_PATH}/tests/unittests/
}

BBCLASSEXTEND = "native nativesdk"

# CVE-2025-14821: fixed in 0.11.4 (libssh advisory: "Versions: libssh < 0.11.4;
# < 0.12.0"); the fix only touches the WIN32 configuration path.
# CVE-2026-15370 and CVE-2026-59843..59850: listed under "version 0.11.5" in
# the upstream CHANGELOG.
# CVE-2026-59842: libssh advisory "Versions: libssh = 0.12.0" (GSSAPI key
# exchange introduced in 0.12.0), so 0.11.x predates the vulnerable code.
CVE_STATUS[CVE-2025-14821] = "fixed-version: fixed in 0.11.4 per libssh advisory; Windows-only configuration path"
CVE_STATUS[CVE-2026-15370] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59843] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59844] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59845] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59846] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59847] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59848] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59849] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59850] = "fixed-version: fixed in v0.11.5"
CVE_STATUS[CVE-2026-59842] = "fixed-version: vulnerable GSSAPI key exchange code introduced in 0.12.0; 0.11.x not affected"
