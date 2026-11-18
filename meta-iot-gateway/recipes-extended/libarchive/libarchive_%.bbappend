# Carried ahead of the layer pin; the pinned layer's wrynose branch ships the
# same change. Remove at the next joint pin move.
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://CVE-2026-15028.patch"

# CVE-2026-4424: RAR LZSS window-size fix (libarchive PR 2898, commits
# d379dc0b2976 and e1907c5832b6), listed in the v3.8.7 release notes; all of
# its checks are present in the 3.8.7 tarball.
CVE_STATUS[CVE-2026-4424] = "fixed-version: fixed in 3.8.7 (libarchive PR 2898, commits d379dc0b2976/e1907c5832b6)"
