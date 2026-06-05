require edge-healthd.inc

# Pin upstream source for reproducible non-externalsrc builds.
# SRCREV corresponds to v0.6.0+5 post-tag on the main branch.
SRCREV = "78b53a464e3c4d5b98f0fabdf91abc5728cd4ae7"
PV = "0.6.0+git${SRCPV}"
