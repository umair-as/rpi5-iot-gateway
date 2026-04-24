# Kernel Driver Backport — Field Guide

How to backport a driver from a downstream kernel (e.g. RPi rpi-6.12.y) into a
mainline kernel carried in a Yocto layer, without devtool.

**Example used:** RPi VCIO mailbox char driver (`/dev/vcio`) from
`github.com/raspberrypi/linux` into mainline 6.18 carried by `linux-iotgw-mainline`.

---

## When to use this approach vs devtool

| Situation | Use |
|-----------|-----|
| Iterating on a recipe's existing source (patches, build flags) | `devtool modify` |
| Backporting a self-contained driver from another tree | **This guide** |
| The patch series is already applied as git commits in `work-shared` | **This guide** |

`devtool modify` checks out the full source into a workspace and wires a bbappend.
For a single driver backport the direct approach is faster and keeps the patch
series clean in the layer.

---

## 1. Find the source in the downstream tree

BitBake mirrors fetched git repos to `DL_DIR/git2/`. Find the relevant mirror:

```bash
ls $DL_DIR/git2/ | grep -i "raspberrypi.*linux\|linux.*rpi"
# github.com.raspberrypi.linux.git
```

Browse it without checking it out:

```bash
RPIGIT="$DL_DIR/git2/github.com.raspberrypi.linux.git"

# List files in a directory
git --git-dir=$RPIGIT ls-tree -r --name-only HEAD | grep "drivers/char/broadcom"

# Read a file
git --git-dir=$RPIGIT show HEAD:drivers/char/broadcom/vcio.c

# Read the Kconfig and Makefile for the subsystem
git --git-dir=$RPIGIT show HEAD:drivers/char/broadcom/Kconfig
git --git-dir=$RPIGIT show HEAD:drivers/char/broadcom/Makefile

# Find where the subsystem is hooked into the parent Kconfig/Makefile
git --git-dir=$RPIGIT show HEAD:drivers/char/Kconfig | grep -A2 "broadcom"
git --git-dir=$RPIGIT show HEAD:drivers/char/Makefile | grep "broadcom"
```

---

## 2. Check what the driver depends on

Before writing a line, verify every dependency is already in the target mainline tree:

```bash
KSRC=build/tmp-glibc/work-shared/raspberrypi5/kernel-source

# Headers the driver includes
grep "#include" drivers/char/broadcom/vcio.c
# → soc/bcm2835/raspberrypi-firmware.h  — check it exists:
ls $KSRC/include/soc/bcm2835/raspberrypi-firmware.h

# Kconfig symbols it depends on
grep "depends on" drivers/char/broadcom/Kconfig
# → BCM2835_MBOX  — check it's compiled in (from an existing fragment):
grep "BCM2835_MBOX" $KSRC/arch/ -r
# or on a running target:
ssh iotgw "zcat /proc/config.gz | grep BCM2835_MBOX"
```

If a dependency is missing, it either needs its own backport first, or you can
satisfy it differently. The VCIO driver needed `BCM2835_MBOX` which was already
pulled in by `rtc-rpi.cfg`.

---

## 3. Decide what to carry

Downstream subsystems often bundle multiple drivers. Only take what you need:

```bash
# Downstream broadcom/ has three drivers:
git --git-dir=$RPIGIT show HEAD:drivers/char/broadcom/Kconfig
# BCM2708_VCMEM   ← not needed
# BCM_VCIO        ← needed for /dev/vcio
# BCM2835_SMI_DEV ← not needed
```

Strip the Kconfig and Makefile to only the driver(s) you carry. Smaller surface =
fewer future conflicts on kernel bumps.

---

## 4. Apply changes in the work-shared kernel source tree

The kernel source at `build/tmp-glibc/work-shared/<machine>/kernel-source/` is a
live git repo with all prior patches applied as commits. Work directly there:

```bash
cd build/tmp-glibc/work-shared/raspberrypi5/kernel-source

# Confirm state — prior patches should be committed
git log --oneline -5
```

Create new files:

```bash
mkdir -p drivers/char/broadcom

# Write Kconfig, Makefile, and driver source
# (copy from downstream, strip to what you need, adjust as required)
$EDITOR drivers/char/broadcom/Kconfig
$EDITOR drivers/char/broadcom/Makefile
$EDITOR drivers/char/broadcom/vcio.c
```

Edit existing hook points:

```bash
# Hook into parent Kconfig — insert before the first 'source' line after menu
$EDITOR drivers/char/Kconfig
# Add: source "drivers/char/broadcom/Kconfig"

# Hook into parent Makefile — append at end
echo 'obj-$(CONFIG_BRCM_CHAR_DRIVERS)	+= broadcom/' >> drivers/char/Makefile
```

Add the Device Tree node (if the driver uses `of_match_table`):

```bash
# Find where the firmware node is defined
grep -rn "raspberrypi,bcm2835-firmware" arch/arm64/boot/dts/broadcom/

# Edit that DTS/DTSI and add the vcio child node inside &firmware {}
$EDITOR arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b-ovl-rp1.dts
# Add inside firmware { } block:
#   vcio: vcio {
#       compatible = "raspberrypi,vcio";
#   };
```

---

## 5. Generate the patch with git

```bash
cd build/tmp-glibc/work-shared/raspberrypi5/kernel-source

git add drivers/char/broadcom/
git add drivers/char/Kconfig
git add drivers/char/Makefile
git add arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b-ovl-rp1.dts

git diff --staged   # review before committing

git commit -m "drivers: char: broadcom: add VCIO mailbox userspace driver"

# Generate format-patch for the last commit
git format-patch HEAD~1 -o /tmp/
# Produces: /tmp/0001-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch
```

Rename to fit your series numbering and copy to the layer:

```bash
cp /tmp/0001-*.patch \
   meta-iot-gateway/recipes-kernel/linux/files/0006-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch
```

Add the `Upstream-Status` tag to the patch header (after `Subject:`):

```
Upstream-Status: Inappropriate [Raspberry Pi downstream driver, not yet in mainline 6.18]
```

---

## 6. Wire into the recipe

In `linux-iotgw-mainline-common.inc` (or the relevant `.bbappend`):

```bitbake
SRC_URI:append = " file://0006-drivers-char-broadcom-add-vcio-mailbox-userspace-driver.patch"
```

If the driver should be opt-in, gate it:

```bitbake
SRC_URI:append = "${@' file://0006-....patch' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"
```

---

## 7. Wire the Kconfig fragment

Create a `.cfg` fragment to enable the new symbols:

```
# meta-iot-gateway/recipes-kernel/linux/files/fragments/vcio-rpi.cfg
CONFIG_BRCM_CHAR_DRIVERS=y
CONFIG_BCM_VCIO=y
```

Add to the fragment class (`iotgw-kernel-fragments.bbclass`):

```bitbake
IOTGW_ENABLE_VCIO ?= "1"
SRC_URI:append = "${@' file://fragments/vcio-rpi.cfg' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"
```

---

## 8. Build and verify

```bash
# Rebuild kernel only first to check patch applies and compiles
kas shell kas/local.yml -c "bitbake virtual/kernel -c patch -f"
kas shell kas/local.yml -c "bitbake virtual/kernel -c compile -f"

# Full bundle when kernel build passes
make bundle-dev-full
```

On target after OTA:

```bash
# Driver loaded
ls -l /dev/vcio

# Verify it works end-to-end
vcgencmd version
vcgencmd measure_temp
vcgencmd get_throttled

# rpi-eeprom-update can now read current config (no longer needs -d fallback)
rpi-eeprom-update
```

---

## Key lessons

**Why not devtool here?**
`devtool modify` is ideal when you are iterating on a recipe's own source —
rebasing patches, editing build config, trying upstream changes. For a
self-contained driver backport, it adds overhead: it checks out the full kernel,
wires a bbappend, and requires `devtool finish` to export. Working directly in
`work-shared` and committing there gives you the same `git format-patch` output
with less ceremony.

**Always generate patches from git, never by hand.**
Hand-written unified diffs require correct hunk line counts (`@@ -a,b +c,d @@`).
Getting these wrong produces "corrupt patch" errors that `git am` and `patch`
both reject. `git format-patch` computes them correctly every time.

**Strip before you carry.**
Downstream subsystems grow organically. Bringing only what you need means fewer
symbols to resolve, fewer potential conflicts on the next kernel bump, and a
patch that is easier to understand and review.

**Check DT bindings — drivers with `of_match_table` need a node.**
A driver that uses Device Tree matching will probe successfully only if a
compatible node exists in the DTB. Always `grep` the downstream DTS for the
`compatible` string to find where the node lives, then add it to your DTS patch.

**Verify dependencies exist in the target tree first.**
A 10-second check (`ls`, `grep`) on headers and Kconfig symbols saves you from
a failed compile that only surfaces after a 20-minute kernel build.
