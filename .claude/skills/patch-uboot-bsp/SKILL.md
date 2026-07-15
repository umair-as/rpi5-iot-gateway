---
name: patch-uboot-bsp
description: Create, refresh, and wire U-Boot source patches in a Yocto layer for BSP changes. Use when modifying board init, environment, boot flow, defconfig, or DTS handling in U-Boot and you need reproducible patch files plus recipe updates (`SRC_URI`, checksums, overrides, or machine-specific appends).
---

# Patch U-Boot BSP

1. Enter the build environment

```bash
kas shell kas/<config>.yml
# or:
source poky/oe-init-build-env build
```

2. Identify the active U-Boot recipe and append chain

```bash
bitbake-layers show-recipes | rg u-boot
bitbake-layers show-appends | rg u-boot
bitbake -e virtual/bootloader | grep '^PREFERRED_PROVIDER_virtual/bootloader='
```

Choose the correct provider recipe (for example `u-boot`, `u-boot-raspberrypi`, or vendor-specific variants).

3. Patch using `devtool` workflow (preferred)

```bash
devtool status
devtool modify <u-boot-recipe>
devtool build <u-boot-recipe>
```

Edit sources in:
- `build/workspace/sources/<u-boot-recipe>/`

Commit inside workspace source tree before finishing:

```bash
cd build/workspace/sources/<u-boot-recipe>
git add -p
git commit -m "u-boot: <what changed for bsp>"
```

Export patches back to your layer:

```bash
devtool finish <u-boot-recipe> <meta-layer-path>
```

`devtool finish` applies committed source-tree changes back to metadata in the
destination layer (roughly `update-recipe` + `reset`) and removes workspace
append wiring for that recipe. In patch mode this typically writes numbered
patch files. Run `devtool status` after finishing to confirm workspace state.

4. Manual patch path (when not using `devtool`)

- Make source edits in your U-Boot tree.
- Generate patch files with `git format-patch`.
- Place patches under recipe files dir, typically:
  `meta-<layer>/recipes-bsp/u-boot/<recipe-or-files>/`
- Ensure patch search path is set in `.bbappend`:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
# or:
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
```

- Add/update `SRC_URI` entries in `.bbappend` or recipe:

```bitbake
SRC_URI:append = " file://0001-...patch"
```

Keep the leading space before `file://` in `SRC_URI:append`; without it, appended entries can concatenate into an invalid URI token.

Use machine or distro overrides when needed:
- `SRC_URI:append:raspberrypi5 = " file://...patch"`

5. Handle defconfig and config fragments correctly

- Defconfig patching:
  - Patch U-Boot defconfig/Kconfig directly only when board defaults must change in source.
  - Treat this as more fragile across upstream rebases.
- Fragment-based config:
  - Prefer layer-managed config fragments when the recipe supports merge flow.
  - Wire fragments via `SRC_URI` and recipe configure logic for better long-term maintainability.

6. Verify the recipe output

```bash
bitbake <u-boot-recipe> -c compile
bitbake <u-boot-recipe>
bitbake <image-name>
```

Validate deployed artifacts (examples):
- `tmp/deploy/images/<machine>/u-boot*.bin`
- `tmp/deploy/images/<machine>/*-bootfiles*`

If the recipe or append includes fetched remote artifacts (not local `file://` patches), update checksum fields as required by fetcher errors (`sha256sum`/`md5sum` entries in `SRC_URI[...]`).

7. Troubleshoot common BSP patch issues

- Patch applies in git but fails in BitBake:
  - Check patch context against exact `SRCREV`.
  - Rebase/regenerate patch series.
- Patch not picked up:
  - Check `.bbappend` filename compatibility (`_<version>.bbappend` vs `_%.bbappend`).
  - Re-check overrides and layer priority.
- Wrong U-Boot provider built:
  - Verify `PREFERRED_PROVIDER_virtual/bootloader` and machine config.

8. Finish cleanly

- If `devtool` workspace is no longer needed:
  `devtool reset <u-boot-recipe>`
- Keep patch filenames stable and ordered for maintainability.
