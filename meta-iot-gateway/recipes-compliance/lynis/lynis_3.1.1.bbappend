## Use the archive location for Lynis 3.1.1 since the top-level URL 404s
# Upstream moved older tarballs under /archive/. Keep the same PV and checksum
# from meta-security, only change the URL so fetch succeeds.

SRC_URI = "https://downloads.cisofy.com/lynis/archive/${BPN}-${PV}.tar.gz"

