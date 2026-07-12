---
name: debug-bitbake
description: Diagnose and fix Yocto/BitBake build failures. Use when tasks fail, recipes are skipped, variables resolve unexpectedly, or logs need root-cause analysis.
argument-hint: "[recipe-name] [task-name]"
allowed-tools: Read, Grep, Glob, Bash(kas *), Bash(bitbake*), Bash(cat *), Bash(less *), Bash(find *), Bash(ls *), Bash(grep *)
---

# Debug BitBake

## Context

- KAS configs: !`ls kas/*.yml 2>/dev/null`
- Machine: !`grep -h 'machine:' kas/*.yml 2>/dev/null | head -3`
- Recent cooker logs: !`find build/tmp/log/cooker/ -name "*.log" -newer build/tmp/log/cooker/ 2>/dev/null | head -3`

## Steps

1. **Identify failing recipe and task** from build output.

2. **Inspect variables**:
```bash
kas shell kas/<config>.yml -c "bitbake <recipe> -e | grep '^<VAR>='"
```

3. **Read task log**:
```bash
find build/tmp/work -path "*/<recipe>/*/temp/log.do_<task>" 2>/dev/null | head -1
```

4. **Re-run specific task**:
```bash
kas shell kas/<config>.yml -c "bitbake <recipe> -c <task> -f"
```

5. **Open devshell** for interactive debugging:
```bash
kas shell kas/<config>.yml -c "bitbake <recipe> -c devshell"
```

6. **Check layer/recipe resolution**:
```bash
kas shell kas/<config>.yml -c "bitbake-layers show-recipes | grep -i <recipe>"
kas shell kas/<config>.yml -c "bitbake-layers show-appends | grep -i <recipe>"
```

## Common Error Patterns

| Error | Likely Cause |
|-------|--------------|
| `Nothing PROVIDES` | Missing DEPENDS or layer not included |
| `do_fetch failed` | Bad URI, network issue, or wrong SRCREV |
| `QA Issue: -dev contains` | Missing RDEPENDS or FILES entries |
| `multiple providers` | Need PREFERRED_PROVIDER in distro/machine conf |
| `do_patch failed` | Patch doesn't apply against current SRCREV |
| `Taskhash mismatch` | Stale sstate — `bitbake <recipe> -c cleansstate` |

For kernel issues, check fragment application and provider selection first.
