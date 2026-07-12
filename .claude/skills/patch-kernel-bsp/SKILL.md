---
name: patch-kernel-bsp
description: Create, refresh, and wire Linux kernel patches in a Yocto layer for BSP changes. Use when modifying board bring-up, drivers, DTS/DTSI, kernel config, or boot/runtime behavior and you need recipe-integrated patch sets and deterministic builds.
---

# Patch Kernel Bsp

1. Enter the build environment

```bash
kas shell kas/<config>.yml
# or:
source poky/oe-init-build-env build
```

2. Identify kernel provider and append chain

```bash
bitbake-layers show-recipes | rg '^linux-|kernel'
bitbake-layers show-appends | rg linux-
bitbake -e virtual/kernel | rg '^PREFERRED_PROVIDER_virtual/kernel='
```

Confirm the active provider (for example `linux-raspberrypi`) from machine/distro configuration.
If your image builds `virtual/kernel`, always verify which concrete recipe currently satisfies it before patching.

3. Patch kernel source with `devtool` (preferred)

```bash
devtool status
devtool modify <kernel-recipe>
devtool build <kernel-recipe>
```

Edit sources in:
- `build/workspace/sources/<kernel-recipe>/`

Commit changes before export:

```bash
cd build/workspace/sources/<kernel-recipe>
git add -p
git commit -m "kernel: <bsp change>"
```

Export patches to layer:

```bash
devtool finish <kernel-recipe> <meta-layer-path>
```

`devtool finish` applies committed source-tree changes back to metadata in the
destination layer (roughly `update-recipe` + `reset`) and removes workspace
append wiring for that recipe. In patch mode this typically exports numbered
patch files. Verify with `devtool status`.

4. Handle device tree and config changes together

- Put DTS/DTSI source changes in patch series when tied to BSP behavior.
- For kernel options, prefer config fragments in layer (not large defconfig rewrites) when project conventions support fragments.
- Ensure fragment wiring in `.bbappend` remains consistent with feature flags and machine overrides.

5. Handle linux-yocto vs vendor kernel differences

- `linux-yocto` + `kernel-yocto` class:
  - Prefer `.scc` feature stacks and `KERNEL_FEATURES` for structured patch/config sets.
  - Relevant tasks and internals include `do_kernel_checkout` and `do_kernel_configme`.
- Vendor kernels (for example `linux-raspberrypi`):
  - Usually rely on plain patch series in `SRC_URI` plus config fragments/defconfig handling in recipe append.
  - Do not assume `.scc` flow exists unless recipe inherits `kernel-yocto`.

6. Choose configuration strategy explicitly

- Defconfig replacement/patch:
  - Useful for major board baselines, but noisy and fragile with upstream movement.
- Config fragments:
  - Preferred for incremental BSP changes.
  - Keep symbols scoped to the feature being changed.
- `KCONFIG_MODE`:
  - Set intentionally when recipe/provider supports it (for example merge vs allnoconfig style behavior).
  - Re-check final `.config` via kernel config tasks after changing mode.

7. Manual patch wiring path (without `devtool`)

- Generate patches from kernel source tree via `git format-patch`.
- Store patches under kernel recipe files directory, commonly:
  `meta-<layer>/recipes-kernel/linux/files/`
- Ensure patch search path is set in `.bbappend`:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
# or:
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
```

- Update recipe/append `SRC_URI`:

```bitbake
SRC_URI:append = " file://0001-...patch"
```

Keep the leading space before `file://` in `SRC_URI:append`; it prevents malformed concatenation when appending.

Use overrides where needed:
- `SRC_URI:append:rpi5 = " file://...patch"`

8. Build and validate

```bash
bitbake <kernel-recipe> -c compile
bitbake <kernel-recipe>
bitbake <image-name>
```

Optional checks:

```bash
bitbake <kernel-recipe> -c menuconfig
bitbake <kernel-recipe> -c diffconfig
```

Validate outputs:
- `tmp/deploy/images/<machine>/Image*`
- `tmp/deploy/images/<machine>/*.dtb`
- modules in rootfs (if driver changes were made)

If fetcher errors reference checksum mismatches for non-`file://` artifacts, update `SRC_URI[...]` checksum entries as required.

9. Troubleshoot kernel BSP patch issues

- Patches fail in BitBake:
  - Confirm patch base matches kernel `SRCREV`.
  - Rebase and regenerate patches in order.
- Config not taking effect:
  - Check fragment precedence, duplicate symbols, and machine overrides.
- DTS changes not present at runtime:
  - Verify correct DTB is installed and selected by bootloader config.

10. Finish cleanly

- Reset workspace when done:
  `devtool reset <kernel-recipe>`
- Keep patch series small and topic-focused for easier long-term BSP maintenance.
