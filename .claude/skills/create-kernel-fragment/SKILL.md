---
name: create-kernel-fragment
description: Create and wire Linux kernel config fragments for Yocto builds. Use when enabling/disabling kernel options, adding driver support, or creating new kernel feature sets.
argument-hint: <feature-name> [CONFIG options...]
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(kas *), Bash(bitbake*), Bash(find *), Bash(ls *)
---

# Create Kernel Fragment

## Context

- Custom layers: !`find . -maxdepth 1 -name "meta-*" -type d 2>/dev/null`
- Existing fragments: !`find meta-*/recipes-kernel/linux/files/ -name "*.cfg" 2>/dev/null`
- Kernel recipes/appends: !`find meta-*/recipes-kernel/linux/ -name "*.bb" -o -name "*.bbappend" -o -name "*.inc" 2>/dev/null`
- Kernel provider: !`grep -rh "PREFERRED_PROVIDER_virtual/kernel" kas/ meta-*/conf/ 2>/dev/null | head -3`
- Feature flags: !`grep -rh "KERNEL_FEATURES\|KERNEL_CONFIG" kas/ meta-*/conf/ 2>/dev/null | head -5`

## Steps

1. **Discover the project's fragment convention** — read existing fragments and the kernel bbappend/include to understand:
   - Where fragments live (e.g. `files/`, `files/fragments/`, `files/cfg/`)
   - Naming pattern (e.g. `feature.cfg`, `igw_feature.cfg`, `cfg/feature.cfg`)
   - How they're wired (unconditional SRC_URI, feature-gated, KERNEL_FEATURES, etc.)

2. **Create the fragment file** following the discovered convention:
```text
# Brief comment explaining the feature
CONFIG_EXAMPLE=y
CONFIG_EXAMPLE_MODULE=m
# CONFIG_EXAMPLE_DEBUG is not set
```
   - Use `=y` for built-in, `=m` for module, `# CONFIG_X is not set` to disable
   - Keep fragments scoped to one feature

3. **Wire the fragment** in the kernel recipe/bbappend/include:
   - Follow the existing wiring pattern (conditional or unconditional)
   - If feature-gated, add the token to the feature variable in KAS yml or distro config

4. **Validate**:
```bash
kas shell kas/<config>.yml -c "bitbake virtual/kernel -c kernel_configcheck"
```

5. **Rebuild kernel**:
```bash
kas shell kas/<config>.yml -c "bitbake virtual/kernel -c compile -f && bitbake virtual/kernel"
```
