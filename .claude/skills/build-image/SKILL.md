---
name: build-image
description: Build Yocto images using BitBake/KAS in any project. Use when asked to build an image recipe, run project wrapper targets, troubleshoot build failures, or locate deploy artifacts.
---

# Build Yocto Image

1. Discover build entrypoints:

```bash
ls kas/*.yml 2>/dev/null
[ -f Makefile ] && rg -n '^[a-zA-Z0-9_.-]+:' Makefile | head -80
bitbake-layers show-recipes | rg '(^|-)image(-|$)|core-image'
```

2. Choose build path:
- If project wrapper targets exist (`make <target>`), use them.
- Otherwise run direct KAS/BitBake:

```bash
kas shell kas/<config>.yml -c "bitbake <image-recipe>"
```

3. Typical output location:
- `build/tmp/deploy/images/<machine>/`

4. If build fails, use targeted diagnostics:
```bash
kas shell kas/<config>.yml -c "bitbake <recipe> -c devshell"
kas shell kas/<config>.yml -c "bitbake <recipe> -e | grep ^<VAR>="
[ -f Makefile ] && make parse && make layers
```

5. Keep secrets/keys in local git-ignored KAS config files (for example `kas/local.yml`).
