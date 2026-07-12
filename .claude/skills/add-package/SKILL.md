---
name: add-package
description: Add a package to Yocto image recipes and rebuild safely. Use when asked to include extra software in any image variant.
argument-hint: <package-name> [image-variant]
allowed-tools: Read, Edit, Grep, Glob, Bash(kas *), Bash(bitbake*), Bash(find *), Bash(ls *)
---

# Add Package To Image

## Context

- Custom layers: !`find . -maxdepth 1 -name "meta-*" -type d 2>/dev/null`
- Image recipes: !`find meta-*/recipes-core/images/ meta-*/recipes-*/images/ -name "*.bb" 2>/dev/null | head -10`
- Packagegroups: !`find meta-*/recipes-core/packagegroups/ meta-*/recipes-*/packagegroups/ -name "*.bb" 2>/dev/null | head -10`
- KAS configs: !`ls kas/*.yml 2>/dev/null`

## Steps

1. **Verify recipe exists** in available layers:
```bash
kas shell kas/<config>.yml -c "bitbake-layers show-recipes | grep -i <package>"
```

2. **Pick the right image recipe** — discover image `.bb` files in the project's custom layer(s). Read the image recipes to understand variants (base, dev, prod, etc.).

3. **Add package with `:append`** (never `+=`):
```bitbake
IMAGE_INSTALL:append = " <package-name>"
```
   - Leading space before package name is mandatory
   - If the package belongs to a feature set, consider adding to a packagegroup instead

4. **If recipe doesn't exist**, check if it needs:
   - A new `.bb` recipe in the project's custom layer
   - A `.bbappend` to customize an upstream recipe
   - Adding a new layer dependency in `kas/*.yml`

5. **Rebuild and verify**:
```bash
make <target>   # or kas build kas/<config>.yml
```
