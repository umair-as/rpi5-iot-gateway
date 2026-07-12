# Recipe & patch conventions (meta-iot-gateway)

Layer-specific additions to Poky's `recipe-style-guide.rst` — that
document is the source of truth for general practice. Read this before
authoring a `.bb`/`.bbappend` or shipping a `.patch` in this layer.

## HOMEPAGE for project-internal recipes

Recipes for code that lives in this layer use the layer URL
(`https://github.com/umair-as/rpi5-iot-gateway`). Recipes wrapping code
with its own upstream point at that repo.

## Patch identity

Locally-authored patches use the maintainer's `git config user.name` /
`user.email`. Patches imported verbatim from upstream preserve original
author attribution; placeholder `From:` values or all-zero `From <SHA>`
lines mean the patch is project-authored and the maintainer identity
applies.

## `/root` install paths

General rule (use `${bindir}`, `${sysconfdir}`, etc.) follows upstream.
`${D}/root/...` literals in `do_install` are accepted:
`iotgw-common.inc` sets `ROOT_HOME ?= "/root"` but composed `kas/*.yml`
layers have not been audited for overrides.

## `Upstream-Status` taxonomy

Every locally-shipped `.patch` carries:

- `Pending`
- `Submitted [<where>]`
- `Backport [<commit-url>]` — verbatim cherry-pick
- `Backport [from <source>; adapted for <target>]` — adapted from upstream
- `Inappropriate [oe specific]` — Yocto build-system mechanics
- `Inappropriate [product specific — <reason>]` — gateway runtime policy

When a patch's commit body cites both an OE-mechanics motivation and a
product-policy motivation, apply the counterfactual test: the motivation
that is *necessary* for the patch's existence determines the tag; the
other goes in the commit body as supporting context.

## `SYSTEMD_AUTO_ENABLE` bare assignment

Bare `SYSTEMD_AUTO_ENABLE = "enable"` is correct when the recipe
produces one package — matches poky convention, not a deviation.
Per-package form is mandatory only when scoping differs across packages
from the same recipe.

## sstate gotcha: patch-header edits trigger full rebuilds

Patch-header edits invalidate sstate even when functionally inert.
Modifying `Upstream-Status:` / `Signed-off-by:` / commit-body text in a
`file://...` patch — text `patch -p1` ignores entirely (it consumes only
what's below `---` / the first `diff` line) — still changes the file's
content hash. BitBake's `do_patch` signature flips and the chain
`do_patch → do_compile → do_install → do_deploy` reruns for the affected
recipe. Batch header edits before triggering a build, or warn the
operator about the rebuild cost upfront. Same applies to
`devtool finish` regenerations (different SHA, different sig).

## Related field guides

- CVE backports: `docs/KERNEL_CVE_PATCH.md`
- Driver backports: `docs/KERNEL_DRIVER_BACKPORT.md`
- Iterating on recipe source: the `devtool-workflow` skill (covers
  patch numbering, workspace branch discipline, and finish verification)
