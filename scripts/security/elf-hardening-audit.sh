#!/bin/bash
# Binary-hardening audit over an extracted rootfs (checksec-equivalent).
#
# Reads every ELF executable and shared object with binutils readelf (any
# architecture; no target tools needed) and reports, per file:
#   pie      yes | lib (shared object) | NO (fixed-address executable)
#   relro    full | partial | NO
#   canary   yes | NO   (references __stack_chk_fail)
#   nx       yes | NO   (GNU_STACK not executable)
#   fortify  yes | NO   (references a *_chk fortified libc function)
#   rpath    yes | no   (RPATH or RUNPATH set)
#   type     ELF type (EXEC, DYN, ...)
#
# Usage:
#   scripts/security/elf-hardening-audit.sh <rootfs-dir> > audit.tsv
#
#   e.g. from an image tarball:
#     D=$(mktemp -d)
#     tar -C "$D" -xf build/tmp/deploy/images/<machine>/<image>.rootfs.tar.zst
#     scripts/security/elf-hardening-audit.sh "$D"
#
# Output: one TSV row per ELF on stdout, columns
#   path pie relro canary nx fortify rpath type
# with path relative to the rootfs; a one-line summary on stderr.
#
# Exit status:
#   0  every executable is PIE, every file has RELRO and a non-executable stack
#   1  at least one file lacks PIE, RELRO or NX (rows with "NO" in those
#      columns). canary and fortify are informational: code with no stack
#      arrays or no fortifiable calls legitimately has neither.
#   2  usage error, rootfs not a directory, or readelf not installed

set -u

usage() { sed -nE '2,/^$/{s/^# ?//p}' "$0"; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi
ROOT="${1%/}"
if [ ! -d "$ROOT" ]; then
    printf 'error: not a directory: %s\n' "$1" >&2
    exit 2
fi
if ! command -v readelf >/dev/null 2>&1; then
    printf 'error: readelf not found (install binutils)\n' >&2
    exit 2
fi

total=0
weak=0
while IFS= read -r -d '' f; do
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
    h=$(readelf -h -l -d -s -W "$f" 2>/dev/null) || continue
    type=$(echo "$h" | sed -n 's/^ *Type: *\([A-Z]*\).*/\1/p' | head -1)
    interp=$(echo "$h" | grep -c "INTERP")
    if [ "$type" = DYN ] && [ "$interp" -gt 0 ]; then pie=yes
    elif [ "$type" = DYN ]; then pie=lib
    elif [ "$type" = EXEC ]; then pie=NO
    else pie="$type"; fi
    if echo "$h" | grep -q "GNU_RELRO"; then
        if echo "$h" | grep -qE "BIND_NOW|FLAGS.*NOW"; then relro=full; else relro=partial; fi
    else
        relro=NO
    fi
    canary=$(echo "$h" | grep -q "__stack_chk_fail" && echo yes || echo NO)
    nx=$(echo "$h" | grep "GNU_STACK" | grep -q "RWE" && echo NO || echo yes)
    fortify=$(echo "$h" | grep -qE "__(printf|sprintf|snprintf|memcpy|memmove|strcpy|strncpy|strcat|read|fgets|vsnprintf|fprintf|vfprintf|realpath|getcwd|recv|poll|longjmp|mempcpy|stpcpy|wcscpy)_chk" && echo yes || echo NO)
    rpath=$(echo "$h" | grep -qE "\(RPATH\)|\(RUNPATH\)" && echo yes || echo no)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${f#"$ROOT"}" "$pie" "$relro" "$canary" "$nx" "$fortify" "$rpath" "$type"
    total=$((total + 1))
    if [ "$pie" = NO ] || [ "$relro" = NO ] || [ "$nx" = NO ]; then
        weak=$((weak + 1))
    fi
done < <(find "$ROOT" -type f \( -perm -u+x -o -name "*.so*" \) -size +1k -print0 2>/dev/null)

printf 'elf-hardening-audit: %d ELF file(s), %d lacking PIE, RELRO or NX\n' "$total" "$weak" >&2
[ "$weak" -eq 0 ]
