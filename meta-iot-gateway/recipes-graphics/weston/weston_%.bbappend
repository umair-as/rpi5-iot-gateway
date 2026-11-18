FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Headless desktop images (weston.ini require-outputs=none, no display
# connected) crash the compositor whenever a client window closes; see the
# patch for the backtrace.
SRC_URI += "file://0001-desktop-shell-do-not-fade-out-a-closing-surface-without-output.patch"
