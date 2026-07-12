#!/bin/bash
# Seed an agent worktree with the operator's kas/local.yml and verify the
# shared Yocto caches are wired, so builds restore from sstate instead of
# compiling cold (minutes vs hours).
#
# Usage (from the MAIN checkout root):
#   .claude/skills/yocto-worktree/scripts/seed-and-verify.sh <worktree-dir>
#   e.g. ... .claude/worktrees/agent-abc123
#
# Exit codes:
#   0  seeded; DL_DIR and SSTATE_DIR resolve outside the worktree's build/
#   1  usage / missing prerequisites (fix before building)
#   2  cache verification failed — do NOT start a build

set -u

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <worktree-dir>"
WT=$1
[ -d "$WT" ] || die "worktree dir not found: $WT"
[ -f scripts/env.sh ] || die "scripts/env.sh not found — run this from the main checkout root"
# No local.yml means no shared-cache config exists to copy. Inventing cache
# paths here would silently produce an hours-long cold build; the operator
# owns this file (see kas/local.yml.example).
[ -f kas/local.yml ] || die "kas/local.yml missing in the main checkout — stop and ask the operator"

cp kas/local.yml "$WT/kas/local.yml" || die "failed to copy kas/local.yml into $WT/kas/"
echo "seeded: $WT/kas/local.yml"

cd "$WT" || die "cannot cd into $WT"
[ -f scripts/env.sh ] || die "$WT has no scripts/env.sh — not a checkout of this repo?"

# env.sh must be sourced in the same shell as the kas call: agent shells do
# not get direnv, and bare kas would re-clone the layer stack into the CWD.
vars=$(. scripts/env.sh && kas shell -c 'bitbake -e | grep -E "^(DL_DIR|SSTATE_DIR)="' kas/local.yml 2>&1 \
       | grep -E '^(DL_DIR|SSTATE_DIR)=')
[ -n "$vars" ] || { echo "ERROR: could not read DL_DIR/SSTATE_DIR via kas — inspect manually:" >&2
                    echo "  . scripts/env.sh && kas shell -c 'bitbake -e | grep -E \"^(DL_DIR|SSTATE_DIR)=\"' kas/local.yml" >&2
                    exit 2; }
echo "$vars"

# A cache dir under this worktree's own build/ means local.yml did not take
# effect (bitbake fell back to ${TOPDIR}-relative defaults) — cold build.
bad=0
for v in DL_DIR SSTATE_DIR; do
    val=$(printf '%s\n' "$vars" | sed -n "s/^$v=\"\(.*\)\"$/\1/p")
    case $val in
        "")             echo "ERROR: $v not set"; bad=1 ;;
        "$PWD"/build/*) echo "ERROR: $v=$val is inside the worktree build dir — shared cache NOT wired"; bad=1 ;;
        *)              echo "OK: $v=$val" ;;
    esac
done
[ "$bad" -eq 0 ] || exit 2
echo "shared caches wired — safe to build"
