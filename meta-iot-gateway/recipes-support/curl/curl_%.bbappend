# CVE-2026-10536: use-after-free in the HTTP/2 stream-dependency tree
# (CURLOPT_STREAM_DEPENDS[_E] + curl_easy_reset() + curl_easy_cleanup()).
# Affected 7.88.0-8.20.0; this build enables HTTP/2 (PACKAGECONFIG nghttp2).
# Upstream's fix removes stream-dependency tracking and makes both options a
# no-op (they become CURLOPTDEPRECATED in curl.h); the backport adapts only
# one lib/url.c context hunk to 8.19.0.
# https://curl.se/docs/CVE-2026-10536.html
#
# Patch files are named CVE-<id>.patch so the scanner links them to the CVE.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2026-10536.patch"

# The recipe sets CVE_STATUS[CVE-2026-10536] to "unpatched" whenever nghttp2
# is enabled, and oe.cve_check.get_patched_cves() lets CVE_STATUS overwrite
# the fix-file-included status a patch file provides. Dropping the flag lets
# the patch file carry the status; re-check this line whenever the recipe's
# own CVE_STATUS for this id changes.
unset CVE_STATUS[CVE-2026-10536]
