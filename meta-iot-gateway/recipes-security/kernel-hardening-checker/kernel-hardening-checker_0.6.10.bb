SUMMARY = "Tool for checking kernel hardening options"
DESCRIPTION = "A script to check kernel configuration options for security hardening. \
Supports analysis against various security guidelines (KSPP, CLIP OS, etc.)."
HOMEPAGE = "https://github.com/a13xp0p0v/kernel-hardening-checker"
LICENSE = "GPL-3.0-only"
LIC_FILES_CHKSUM = "file://LICENSE.txt;md5=d32239bcb673463ab874e80d47fae504"

SRCREV = "v${PV}"
SRC_URI = "git://github.com/a13xp0p0v/kernel-hardening-checker.git;branch=master;protocol=https"

S = "${WORKDIR}/git"

inherit python3native

RDEPENDS:${PN} = "python3-core"

do_install() {
    install -d ${D}${bindir}
    install -d ${D}${datadir}/kernel-hardening-checker
    # Install full source tree as data to keep helper modules available
    cp -R --no-preserve=ownership ${S}/* ${D}${datadir}/kernel-hardening-checker/

    # Install a convenient launcher in PATH
    if [ -x ${S}/khc ]; then
        install -m 0755 ${S}/khc ${D}${bindir}/kernel-hardening-checker
    elif [ -f ${S}/kernel-hardening-checker.py ]; then
        install -m 0755 ${S}/kernel-hardening-checker.py ${D}${bindir}/kernel-hardening-checker
    else
        # Fallback: wrapper that invokes the bundled entrypoint with proper PYTHONPATH
        cat > ${D}${bindir}/kernel-hardening-checker << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
base="/usr/share/kernel-hardening-checker"
export PYTHONPATH="${base}:${PYTHONPATH:-}"
exec python3 "${base}/bin/kernel-hardening-checker" "$@"
EOF
        chmod 0755 ${D}${bindir}/kernel-hardening-checker
    fi
}

FILES:${PN} += "${datadir}/kernel-hardening-checker"

BBCLASSEXTEND = "native nativesdk"
