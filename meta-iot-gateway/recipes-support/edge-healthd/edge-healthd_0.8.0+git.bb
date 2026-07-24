require edge-healthd.inc

# Pin upstream source for reproducible non-externalsrc builds.
# SRCREV is the v0.8.0 release tag (github.com/umair-as/edge-healthd).
SRCREV = "100a13ec1ac44556aea699ecc70d0ca200047ae0"
PV = "0.8.0+git${SRCPV}"
