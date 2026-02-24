#!/bin/bash
# SPDX-License-Identifier: MIT
# boot-backup-prune: prune old /boot backup artifacts

set -euo pipefail

log_info()  { echo "[$(date -Iseconds)] [INFO]  🩺 $*" >&2; }
log_warn()  { echo "[$(date -Iseconds)] [WARN]  ⚠️  $*" >&2; }

DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: boot-backup-prune [-n|--n|--dry-run]

Options:
  -n, --n, --dry-run   Show what would be deleted, do not remove files.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--n|--dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

prune_boot_backups() {
    local boot_mp="/boot"
    local keep="${MAX_BOOT_BACKUPS_AFTER_GOOD:-2}"
    local ro_before="0"
    local rw_prepared="0"
    local deleted=0
    local found=0
    local bases

    [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
    [ -d "$boot_mp" ] || return 0
    mountpoint -q "$boot_mp" || return 0

    bases=$(find "$boot_mp" -maxdepth 2 -type f -name '*.bak*' 2>/dev/null \
        | sed -E 's/\.bak(\..*)?$//' \
        | sort -u || true)

    if [ -n "$bases" ]; then
        while IFS= read -r base; do
            [ -n "$base" ] || continue
            found=1
            dir=$(dirname "$base")
            bn=$(basename "$base")
            list=$(find "$dir" -maxdepth 1 -type f -name "${bn}.bak*" -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr \
                | awk '{print $2}' || true)
            [ -n "$list" ] || continue
            prune=$(echo "$list" | awk -v n="$keep" 'NR>n {print}')
            if [ -n "$prune" ]; then
                while IFS= read -r f; do
                    [ -n "$f" ] || continue
                    if [ "$DRY_RUN" -eq 1 ]; then
                        log_info "[dry-run] Would delete: $f"
                    else
                        if [ "$rw_prepared" = "0" ]; then
                            if findmnt -no OPTIONS "$boot_mp" 2>/dev/null | grep -qw ro; then
                                ro_before="1"
                                mount -o remount,rw "$boot_mp" >/dev/null 2>&1 || {
                                    log_warn "Could not remount $boot_mp rw for backup cleanup"
                                    return 0
                                }
                            fi
                            rw_prepared="1"
                        fi
                        rm -f -- "$f" || true
                        deleted=$((deleted + 1))
                    fi
                done <<< "$prune"
            fi
        done <<< "$bases"
    fi

    if [ "$ro_before" = "1" ]; then
        mount -o remount,ro "$boot_mp" >/dev/null 2>&1 || true
    fi

    if [ "$found" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "Boot backup dry-run complete: keep=${keep}"
        else
            log_info "Boot backup cleanup complete: deleted=${deleted}, keep=${keep}"
        fi
    else
        log_info "No boot backup artifacts found under ${boot_mp}"
    fi
}

prune_boot_backups
