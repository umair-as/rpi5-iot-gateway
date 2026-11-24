# CVE_STATUS — narrowly-evidenced VEX for sbom-cve-check matches already fixed
# in the shipped CPython point release.
#
# All of the following were backported to CPython 3.14.4 (affected 3.14.0-3.14.3);
# this image ships 3.14.10. The scanner's "fixed from 3.15.0" hint reflects the
# 3.15-alpha main-branch fix and misses the 3.14.4 stable backport; per-CVE OSV
# ranges confirm 3.14.4 is the first fixed 3.14.x release.
#   https://osv.dev/vulnerability/CVE-2025-13462  (tarfile DIRTYPE normalization)
#   https://osv.dev/vulnerability/CVE-2026-2297   (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3644    (http.cookies control chars)
#   https://osv.dev/vulnerability/CVE-2026-4224    (fixed 3.14.4)
#   https://osv.dev/vulnerability/CVE-2026-3479    (fixed 3.14.4; also PSF-disputed, CVSS 0.0)
#
# imaplib CVE-2025-15366: fixed upstream in 3.14.7 (CNA record: 3.14.0 up to
# but excluding 3.14.7 affected), in a refined form that rejects NUL/CR/LF in
# command arguments and quotes other control characters (Lib/imaplib.py
# _control_chars; NEWS gh-40038). The stricter 3.15.0a6 fix does not apply
# on 3.14.x.
#   https://github.com/python/cpython/issues/143921
#
# poplib CVE-2025-15367: affected below 3.15.0a6, no 3.14 backport upstream;
# 3.14.10's POP3._putcmd still has no check, so it is carried as a backport.
# The file is named CVE-<id>.patch because oe.cve_check.parse_cves_from_patch_file()
# reads the id from the FILENAME (or a "CVE:" line) and the scanner otherwise
# reports the CVE as Unpatched. The backport's header is left untouched.
#
# Changing SRC_URI rebuilds python3-NATIVE (BBCLASSEXTEND), whose sysroot feeds
# rpm-native and so do_package for every recipe: batch such edits with other
# source-affecting changes.
CVE_STATUS[CVE-2025-13462] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-2297] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3644] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-4224] = "fixed-version: fixed in CPython 3.14.4 (shipped)"
CVE_STATUS[CVE-2026-3479] = "disputed: PSF-disputed, CVSS 0.0; also fixed in 3.14.4 (shipped)"
CVE_STATUS[CVE-2025-15366] = "fixed-version: fixed in CPython 3.14.7 (3.14.10 shipped); CNA lists 3.14.0 to <3.14.7 affected"
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2025-15367.patch"

