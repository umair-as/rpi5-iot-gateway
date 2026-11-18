SUMMARY = "IoT GW DEEPX DX-M1 accelerator stack"
DESCRIPTION = "Kernel modules, DXRT runtime and tooling for the DEEPX DX-M1 \
PCIe NPU. Pulled into an image only when IOTGW_ENABLE_DEEPX_DXM1 = 1."
LICENSE = "MIT"

inherit packagegroup

# Not allarch: RDEPENDS on kernel modules, whose package names carry the
# kernel version and are machine-specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# FAIL FAST. Enabling the feature without composing kas/deepx.yml would
# otherwise surface as "Nothing PROVIDES dx-rt" deep in a dependency chain,
# which reads like a broken recipe rather than a missing overlay.
python __anonymous() {
    if d.getVar("IOTGW_ENABLE_DEEPX_DXM1") != "1":
        return
    collections = (d.getVar("BBFILE_COLLECTIONS") or "").split()
    if "meta-deepx-m1" not in collections:
        bb.fatal(
            "IOTGW_ENABLE_DEEPX_DXM1 = 1 but the meta-deepx-m1 layer is not in "
            "the composition. The DX-M1 driver, runtime and demo all live in "
            "that layer. Compose it:\n"
            "    make base|dev|desktop (they compose it)\n"
            "  or: kas <base>:kas/deepx.yml\n"
            "Enabling the toggle alone does not add the layer — the two are "
            "deliberately separate."
        )
}

# The accelerator itself: signed out-of-tree modules + the DXRT runtime.
#
# dx_dma is the PCIe driver; dxrt_driver is the runtime char device. Their load
# ORDER matters and is handled by the softdep the driver ships
# ("softdep dx_dma pre: dxrt_driver"), so autoloading dx_dma alone is
# sufficient — see the dx-driver bbappend.
# NOTE: depend on dx-rt only, NOT dx-rt-cli / dx-rt-examples.
# Upstream declares PACKAGES:append = " ${PN}-cli ${PN}-examples", which puts
# them AFTER ${PN} in the packaging order. ${PN}'s default FILES already claims
# ${bindir}/*, so it takes every binary first and the two later packages come
# out EMPTY — OE then skips them, and depending on them fails do_rootfs with
# "nothing provides dx-rt-examples". Their intended split silently does not
# happen. All the tools we need (dxrtd, dxrt-cli, run_model, dxtop,
# dxbenchmark) ship in dx-rt itself.
# dx-driver rather than the kernel-module-* packages directly: those are named
# kernel-module-<name>-${KERNEL_VERSION} with no versionless RPROVIDES, so they
# cannot be named stably from here. The dx-driver bbappend makes that package
# depend on its own modules, which keeps the kernel version out of this recipe.
RDEPENDS:${PN} = " \
    dx-driver \
    dx-rt \
    iotgw-deepx-runtime \
    iotgw-dx-demo-probe \
"

# The demo group is a separate recipe, packagegroup-iot-gw-deepx-demo.bb: a
# package of THIS recipe would make every image that takes the stack above
# resolve the demo's Wayland dependencies too (iotgw-dx-demo -> weston-init),
# which a headless image cannot.
