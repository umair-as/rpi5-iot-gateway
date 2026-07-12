# Yocto/BitBake Patterns

## BitBake Shell-Parser Limits

BitBake's shell parser does **not** support POSIX arithmetic expansion
`$((…))` in recipe shell snippets — parsing fails with
`NotImplementedError: $((`. Use `case` patterns or `expr` to
count/increment. (Caught while generalizing the FIT trust-root counting
in `linux-iotgw-mainline-fit_6.18.bb`.)

## Deploy-Artifact Mutations Live Only in DEPLOYDIR

When a recipe mutates deploy artifacts in `do_deploy:append`, each
kernel/u-boot rebuild starts from a fresh artifact in the build dir;
mutations exist only in `DEPLOYDIR`. No cleanup of previous-run residue
is needed.

## Override Syntax (Scarthgap+)

Use colon-based overrides, not underscore:

```bitbake
# Correct (Scarthgap)
RDEPENDS:${PN} = "dep"
do_install:append() { }
SRC_URI:append:raspberrypi5 = " file://rpi5.patch"

# Wrong (deprecated)
RDEPENDS_${PN} = "dep"
do_install_append() { }
```

## File Paths

Always use variables, never hardcode:

| Variable | Expands To |
|----------|------------|
| `${bindir}` | /usr/bin |
| `${sbindir}` | /usr/sbin |
| `${libdir}` | /usr/lib or /usr/lib64 |
| `${sysconfdir}` | /etc |
| `${datadir}` | /usr/share |
| `${systemd_system_unitdir}` | /lib/systemd/system |

## License Checksums

Generate with:

```bash
md5sum LICENSE
# or for specific lines
head -n 20 LICENSE | md5sum
```

Format: `file://LICENSE;md5=<hash>` or `file://LICENSE;beginline=1;endline=20;md5=<hash>`

## SRCREV Pinning

```bash
# Get current HEAD
git ls-remote https://github.com/user/repo.git HEAD

# In recipe
SRCREV = "abc123def456..."  # Full 40-char SHA
PV = "1.0.0+git${SRCPV}"    # Include git rev in version
```

## do_install Pattern

```bitbake
do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/myapp ${D}${bindir}/myapp
    
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/myapp.conf ${D}${sysconfdir}/
    
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/myapp.service ${D}${systemd_system_unitdir}/
}
```

## FILES Variable

```bitbake
FILES:${PN} += "${sysconfdir}/myapp.conf"
FILES:${PN}-dev += "${includedir}/*.h"
```

## PACKAGECONFIG Best Practice

```bitbake
# Define all options
PACKAGECONFIG ??= "ssl"
PACKAGECONFIG[ssl] = "--with-ssl,--without-ssl,openssl"
PACKAGECONFIG[debug] = "--enable-debug,--disable-debug"

# Enable in local.conf or image
PACKAGECONFIG:append:pn-myapp = " debug"
```

## Cross-recipe identity (USERADD_PARAM / supplementary groups)

**Don't** put `--groups <X>` in `USERADD_PARAM` when `<X>` is created by a
*different* recipe in this layer. Rootfs assembly doesn't guarantee recipe
B's `groupadd` runs before recipe A's `useradd --groups <B-group>`. When
the ordering loses the race, `useradd` fails *atomically* — recipe A's
primary user AND group both vanish. Hit on prod 2026-05-26: PR #84 fixed.

Safe `--groups` uses: base-passwd groups that land in `/etc/group` very
early — `dialout`, `tty`, `audio`, `video`, `kvm`, `render`, `disk`,
`wheel`, `root`. Anything else is project-owned and must be handled via
the reconciler.

**Do** declare cross-recipe supplementary memberships via
`IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS` in `meta-iot-gateway/conf/distro/include/iotgw-common.inc`
(or wherever the feature gate lives). The hook in
`meta-iot-gateway/classes/iotgw-rootfs.bbclass` mutates `/etc/group`
at `ROOTFS_POSTPROCESS_COMMAND` time, after all `useradd`/`groupadd`
processing has completed. Race-safe, deterministic.

```bitbake
# iotgw-common.inc — gated example
IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS += "${@'ota:iotgwtpm' if (... gate ...) else ''}"
```

The reconciler `bbfatal`s if a declared user or group is absent from the
staged rootfs — if the feature gate asked for the membership but either
side wasn't pulled in via `RDEPENDS`, the image is internally inconsistent
and we want a loud build failure, not a silent skip.

**Do not** use `pkg_postinst_ontarget:${PN}` for cross-recipe identity work,
and **do not** use the `pkg_postinst:${PN}() { if [ -n "$D" ]; then exit 0; fi … }`
pattern in this layer. The prod image set does not ship
`run-postinsts.service`, so deferral via either of those paths silently
fails — the body never runs on target. Always use the rootfs-postprocess
mechanism instead.
