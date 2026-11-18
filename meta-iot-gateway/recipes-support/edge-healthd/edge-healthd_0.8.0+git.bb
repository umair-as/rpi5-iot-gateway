require edge-healthd.inc

# Pin upstream source for reproducible non-externalsrc builds.
# SRCREV is a main-branch commit after the v0.8.0 tag (github.com/umair-as/edge-healthd):
# it carries the daemon running without a writable state directory, which a
# boot without /data needs.
SRCREV = "4ac4e6c808c55b37451cb7b44577e7e378591f40"
PV = "0.8.0+git${SRCPV}"
