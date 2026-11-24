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

### Patch headers: attribution and sign-off

No `Assisted-by:` line in new or modified patch headers (`AGENTS.md`
§"AI attribution"). Patches that already carry one keep it: removing it
is a header edit, which forces a rebuild (§"sstate gotcha" below) and
changes nothing a reader needs.

- `Inappropriate [...]`, `Pending`, `Submitted [<where>]`: the patch is
  ours; the header is `Upstream-Status:` and the maintainer's
  `Signed-off-by:`. For a submitted patch, the receiving project's rules
  on tags and tool-use disclosure win at submission time; check its
  current contribution docs before sending.
- `Backport [...]` (verbatim and adapted): **do not touch the header.**
  The commit message and its `Signed-off-by:` chain belong to the
  original author (e.g. the rpi RTC driver patch carries popcornmix' and
  Jonathan Bell's sign-offs). Only the `Upstream-Status:` line is ours to
  add. **Exception: CVE security backports — see below.**

`Signed-off-by:` stays last and stays a **human**: the DCO sign-off
certifies who takes responsibility for the patch. An agent never adds —
or requests — a sign-off on its own initiative.

**CVE security backports are the one exception, and only when the operator
explicitly asks for a sign-off in that session** — never by default, never
inferred from "this is a CVE fix." This holds however the backport was
produced.

When one is asked for, the invariants are:

- **Never overwrite or remove an existing upstream `Signed-off-by:`** —
  append below it. Each backporter adds their own line, chain-of-custody
  style; see the CVE-2022-3341 FFmpeg example in the
  [Yocto security manual](https://docs.yoctoproject.org/security-manual/vulnerabilities.html#fixing-vulnerabilities-in-recipes).
- **Use the operator's real resolved identity** — never a placeholder,
  never an automation identity.
- **Add it only on that explicit request**, in that session.

Everywhere else, the Backport rule above stands unchanged: don't touch
the header, no sign-off unless asked.

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
