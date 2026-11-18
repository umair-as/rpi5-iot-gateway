SUMMARY = "IoT GW DEEPX DX-M1 inference demo"
DESCRIPTION = "DX-M1 demo payload, DX-Stream GStreamer elements and the \
Wayland demo launcher, on top of packagegroup-iot-gw-deepx. Desktop image only."
LICENSE = "MIT"

inherit packagegroup

# Follows packagegroup-iot-gw-deepx, which is machine-specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Demo tooling. Separate from packagegroup-iot-gw-deepx so base, dev and
# (later) prod take the driver and runtime without the examples, the 77 MB
# sample payload, the GStreamer stack or the Wayland launcher. A package of
# that recipe would not do: bitbake resolves the runtime dependencies of every
# package a recipe produces, so headless images would need weston-init.
#
# LICENSING: every DEEPX package here is LICENSE = "Proprietary" under a
# customer-only licence (see the dx-driver bbappend). Fine for a development
# image on a board whose owner holds a DX-M1. An image containing these must
# not be redistributed.
#
# dx-rt-examples omitted for the same reason as dx-rt-cli (see
# packagegroup-iot-gw-deepx.bb): it is an
# empty package that is never produced. The sample payload carries the model,
# video and run script, which is what the demo actually needs.
# dx-stream is required: without it the sample is inert: the payload's
# run.sh is a GStreamer pipeline
#
#   urisourcebin ! decodebin ! dxpreprocess ! dxinfer ! dxpostprocess ! dxosd
#   ! videoconvert ! waylandsink
#
# and dxpreprocess/dxinfer/dxpostprocess/dxosd are GStreamer ELEMENTS shipped by
# dx-stream, not by dx-stream-sample. Shipping only the sample gave a model, a
# video and a script that cannot run — which is exactly what the headless dev
# image did, and why the on-screen demo was impossible there.
#
# dx-stream also needs a Wayland compositor and the oe-core GStreamer stack, so
# this group is only meaningful in the desktop image. Headless images pull
# packagegroup-iot-gw-deepx only.
#
# NOTE: dx-stream requires the wrynose S port in
# dynamic-layers/meta-deepx-m1/recipes-runtime/dx-stream/dx-stream_%.bbappend.
# Its build deps (opencv, librdkafka, libeigen from meta-oe; libyuv from
# meta-deepx-m1 itself) all resolve in the current composition — verified by
# recipe search — but opencv is a heavy first-time build; budget for it.
RDEPENDS:${PN} = " \
    packagegroup-iot-gw-deepx \
    dx-stream \
    dx-stream-sample \
    iotgw-dx-demo \
"
