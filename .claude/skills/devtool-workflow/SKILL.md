---
name: devtool-workflow
description: "Modify, build, and upstream patches for any Yocto recipe using devtool. Use when iterating on a recipe's source (BSP, kernel, U-Boot, app) without editing the recipe directly. Covers the full cycle: modify, build, commit, finish, verify."
metadata:
  argument-hint: "<recipe-name> [modify|build|finish|reset|deploy]"
allowed-tools: "Read, Edit, Grep, Glob, Bash(kas *), Bash(bitbake*), Bash(devtool *), Bash(git *), Bash(cd *), Bash(find *), Bash(ls *)"
---

# devtool Workflow

## Context

- KAS configs: !`ls kas/*.yml 2>/dev/null`
- Custom layers: !`find . -maxdepth 1 -name "meta-*" -type d 2>/dev/null`
- Workspace status: !`test -d build/workspace && kas shell kas/local.yml -c "devtool status" 2>/dev/null || echo "no active workspace"`

---

## How devtool Works (Read This First)

`devtool modify` creates a workspace layer at `build/workspace/` containing:

```
build/workspace/
  sources/<recipe>/     ← git repo: upstream source + project patches as commits
  appends/<recipe>.bbappend  ← wires externalsrc to the workspace source
  recipes/              ← (used by devtool add, not modify)
  attic/                ← preserved source if devtool reset detects modifications
```

The default development branch inside `build/workspace/sources/<recipe>/` is
`devtool` (unless `devtool modify --branch <name>` is used). Keep all project
work on the branch used for the modify session.
`devtool finish` applies committed source-tree changes back to metadata in the
destination layer (roughly `update-recipe` + `reset`). In patch mode, this
typically means numbered patch files and recipe/append `SRC_URI` updates.

---

## Project Guardrails (Stricter Than Upstream Docs)

These are team safety rules for predictable patch generation. Upstream Yocto
docs do not require all of them, but following them avoids common failures.

1. **Always verify branch before any git operation:**
   ```bash
   git branch   # must show your modify branch (default: * devtool)
   ```
   If not on the intended branch, checkout that branch before proceeding.

2. **Never use `git commit --amend` in a devtool workspace.**
   Amend on the `devtool` branch rewrites the base commit boundary. Amend on
   `master` or any other branch contaminates upstream content into your diff.
   Neither is recoverable without a full `devtool reset`.

3. **Never use `git format-patch` manually.**
   Always use `devtool finish` to extract patches back to the layer. Manual
   `format-patch` bypasses devtool's patch numbering, layer wiring, and
   SRC_URI management.

4. **Do not cherry-pick or rebase in the workspace in this project.**
   If commit restructuring is required, prefer `devtool reset` and re-apply
   changes cleanly on the active modify branch.

5. **Verify patch content after every `devtool finish`.**
   See step 6a below. Do not rebuild or commit to the layer until verified.

---

## 1. Enter Build Environment

```bash
kas shell kas/<config>.yml
```

---

## 2. Check Workspace State

Always check before starting. Avoid conflicts with existing workspace entries.

```bash
devtool status
```

If recipe is already in workspace and you want a clean start:

```bash
devtool reset <recipe>   # source preserved in attic unless modified
```

---

## 3. Check Out Recipe for Editing

Detect whether recipe metadata uses conditional `SRC_URI` operations (which can
break `devtool modify` override-branch handling):

```bash
bitbake-getvar -r <recipe> SRC_URI 2>/dev/null | grep -E "(:append:|:prepend:|:remove:)" || true
```

If conditionals are present (or if previous `devtool modify` failed with
override-branch messages), use:

```bash
devtool modify --no-overrides <recipe>
```

Otherwise use:

```bash
devtool modify <recipe>
```

- Downloads and unpacks upstream source into `build/workspace/sources/<recipe>/`
- Applies existing recipe patches as commits on top of upstream
- Creates a working branch (default name: `devtool`; configurable with `--branch`)
- Wires `externalsrc` bbappend automatically

**Non-patch `file://` entries and `oe-local-files`:**
When `devtool modify` runs, non-patch `file://` SRC_URI entries (`.cfg` fragments,
`fw_env.config`, scripts — anything that is not `.patch` or `.diff`) are copied to
an `oe-local-files/` subdirectory under the workspace source tree. If this directory
does not exist when `devtool finish` runs, devtool interprets its absence as
intentional deletion and removes those files from the layer. Always verify it is
populated before finishing.

```bash
ls build/workspace/sources/<recipe>/oe-local-files/
# Must list your .cfg fragments, fw_env.config, etc. before devtool finish
```

Force-disable override branch generation explicitly when needed:

```bash
devtool modify --no-overrides <recipe>
```

Immediately after `devtool modify`, verify branch state:

```bash
cd build/workspace/sources/<recipe>
git branch          # must show: * devtool
git log --oneline   # verify: upstream base + existing patches visible as commits
```
If you used `--branch <name>`, replace `devtool` with that branch name in all
checks below.

---

## 4. Build Modified Recipe

```bash
devtool build <recipe>
```

For a full image rebuild:

```bash
bitbake <image-name>
```

Optional — deploy directly to a running target for fast iteration:

```bash
devtool deploy-target <recipe> root@<target-ip>
# Undo:
devtool undeploy-target <recipe> root@<target-ip>
```

---

## 5. Make and Commit Changes

**Before touching any file:**

```bash
cd build/workspace/sources/<recipe>
git branch          # MUST show your active modify branch — stop if it does not
```

Make your changes, then commit:

```bash
git add -p          # stage changes selectively
git commit -m "component: describe what and why"
```

Commit message conventions:
- One logical change per commit
- Subject line: `component: short description` (e.g. `defconfig: disable redundant env`)
- Body: explain *why*, not just *what* — this becomes the patch header

**Multiple commits are fine and preferred over one large commit.**
`devtool finish` produces one numbered patch file per commit.

**Uncommitted changes are silently dropped by `devtool finish`.** Commit everything.

---

## 6. Finish — Write Patches Back to Layer

Identify the target layer path first, then:

```bash
devtool finish <recipe> <path-to-layer>
# Example:
devtool finish u-boot meta-iot-gateway/
```

`devtool finish`:
- Pushes committed changes from the source tree back to metadata in destination layer
- In patch mode, converts commit deltas to numbered `.patch` files
- Updates recipe or bbappend metadata (typically `SRC_URI`) as needed
- Removes the workspace bbappend
- Resets the workspace entry

---

## 6a. Verify Generated Patches (Mandatory)

**Always run these checks before rebuilding or committing the layer.**

```bash
# 1. Confirm only expected files were touched in the layer
git diff --name-only <layer>/recipes-<category>/<recipe>/files/

# 2. Confirm each patch touches only intended files
#    For a defconfig patch: only configs/<defconfig> should appear
grep "^---\|^+++" <layer>/recipes-<category>/<recipe>/files/00*.patch \
  | grep -v "configs/rpi_arm64_defconfig\|/dev/null"
# Expected: empty — if non-empty, patch is contaminated with wrong files

# 3. Confirm no upstream release artifacts crept in
grep -lE "Makefile|CHANGELOG|statistics|release notes" \
  <layer>/recipes-<category>/<recipe>/files/00*.patch
# Expected: no output

# 4. Confirm patch count matches your commit count
ls <layer>/recipes-<category>/<recipe>/files/00*.patch | wc -l
# Compare against: git log --oneline <work-branch> ^<upstream-base> | wc -l
```

If any check fails:

```bash
devtool reset <recipe>
devtool modify <recipe>
# Re-verify branch, re-apply changes cleanly on devtool branch
devtool finish <recipe> <layer-path>
# Re-run verification
```

---

## 7. Reset Without Finishing

```bash
devtool reset <recipe>
```

- Workspace bbappend removed; recipe build returns to layer version
- By default, source tree is left in place under `build/workspace/sources/<recipe>/`
- With `devtool reset -r` / `devtool finish -r`, source cleanup is requested; if
  modified, devtool may preserve source in `build/workspace/attic/sources/<recipe>.<timestamp>/`
- To reuse attic source: `devtool modify <recipe> <path-to-attic-source>`
- Delete attic manually when no longer needed

---

## Defconfig Workflow (U-Boot / Kernel)

When the change involves Kconfig (defconfig patches), the workflow has an extra
step to ensure Kconfig dependency resolution is captured correctly.

```bash
# After devtool modify, inside workspace source directory:
git branch          # verify active modify branch (default: * devtool)

# Generate baseline defconfig
make <board>_defconfig
make savedefconfig
cp defconfig defconfig.upstream

# Merge project fragments
scripts/kconfig/merge_config.sh .config /path/to/project-fragment.cfg
# Review merge output — "value redefined" warnings are expected for
# options already resolved by upstream Kconfig dependency logic

# Capture resolved config
make savedefconfig

# Verify expected options
grep -c "OPTION_YOU_EXPECT" defconfig

# Commit ONLY the defconfig file — not .config, not upstream files
git add configs/<board>_defconfig
git branch          # verify active modify branch — one last check before commit
git commit -m "defconfig: apply <project> base hardening"

# Proceed to devtool finish + 6a verification
```

**Why savedefconfig instead of a raw fragment?**
Kconfig dependency resolution causes implicit options to appear or disappear
when explicit options change. A `savedefconfig` patch captures the fully-resolved
truth. Raw fragments are fragile — the effective config delta is larger than the
fragment declares, and silent regressions are possible on U-Boot version bumps.

Add a regeneration comment at the top of defconfig patches:

```
# Generated by savedefconfig against <recipe> <version/commit>.
# Regenerate on version bump:
#   devtool modify <recipe> → make <board>_defconfig →
#   merge_config.sh + project fragments → make savedefconfig →
#   devtool finish
```

---

## Recovery Procedures

### Wrong branch commit

Symptom: committed on `master` or non-work branch.

```bash
git log --oneline master | head -5   # check if your commit is on master
git log --oneline <work-branch> | head -5  # check intended branch state

# If work branch is clean and master has the wrong commit:
git checkout master
git revert HEAD --no-edit           # or git reset HEAD~1 if not yet pushed

# Re-apply changes on intended work branch:
git checkout <work-branch>
# Re-make and re-commit changes
```

If in doubt, reset entirely:

```bash
devtool reset <recipe>
devtool modify <recipe>
# Start from step 5 with clean devtool branch
```

### Contaminated patch after devtool finish

Symptom: patch contains Makefile, CHANGELOG, release notes, or other upstream files.

```bash
# Do not rebuild. Do not commit the layer.
devtool reset <recipe>
devtool modify <recipe>
git branch   # verify active modify branch
# Re-apply ONLY your intended changes as new commits
devtool finish <recipe> <layer-path>
# Run 6a verification before proceeding
```

### devtool finish fails — layer path issues

```bash
devtool finish <recipe> <layer-path> --no-clean   # preserve workspace on failure
# Check: layer path exists and is writable
ls -la <layer-path>/recipes-<category>/<recipe>/
```

---

## Common Pitfalls

- **Wrong branch commits**: Always `git branch` before `git add`. Committing on
  the wrong branch risks unintended patch content; recover by reverting and
  recommitting on the active modify branch, or reset/restart.
- **`git commit --amend` in workspace**: Rewrites the commit boundary devtool uses
  to determine which commits become patches. Project rule: avoid amend here.
- **`git format-patch` instead of `devtool finish`**: Bypasses patch numbering and
  recipe/bbappend updates. Always use `devtool finish` / `devtool update-recipe`.
- **Uncommitted changes**: `devtool finish` silently drops them. Always commit first.
- **`AUTOREV` recipes**: Pin `SRCREV` explicitly after finishing.
- **"already in your workspace" error**: Run `devtool reset <recipe>` first.
- **Defconfig patches that include wrong files**: Always run 6a verification.
  Rebuild only after verification passes.
- **Version bump breaks defconfig patch**: Regenerate via the defconfig workflow
  above against the new version. Do not attempt to manually rebase patch hunks.
