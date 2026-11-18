#!/usr/bin/env bash
# Guarded, operator-run updater for the shared Raspberry Pi 5 boot files.
#
# A RAUC install writes only the target slot's signed FIT. The files below
# are single-copy on the FAT /boot (no A/B), so they change only through this
# tool, never unattended:
#   kernel_2712.img      U-Boot, the firmware's default kernel (as the WIC
#                        installs it)
#   bcm2712-rpi-5-b.dtb  firmware control FDT and U-Boot's FIT trust anchor;
#                        it must still trust both installed slot FITs
#   config.txt           read by the firmware first; it must not name a kernel
#                        other than U-Boot
# Every check runs before the first write, and the current files are backed
# up to /data first. Each file is copied to a temporary name, synced, read
# back from the medium, renamed over the target and read back again. FAT has
# no journal: a power cut during the rename leaves the target old or new,
# possibly with lost clusters that fsck.vfat repairs at the next boot.
# --restore <run-id> writes a backup back through the same guards.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR=${ROOT_DIR:-/usr/share/iotgw/rpi-boot}
MANIFEST=${MANIFEST:-${ROOT_DIR}/manifest.tsv}
BOOT_MP=${BOOT_MP:-/boot}
# Must survive a reboot: /var/lib is a volatile overlay on the verity rootfs.
BACKUP_DIR=${BACKUP_DIR:-/data/rpi-boot/backup}
ANCHOR_LIB=${IOTGW_FIT_ANCHOR_LIB:-/usr/lib/iotgw/iotgw-fit-anchor.sh}
ANCHOR=bcm2712-rpi-5-b.dtb
# Tests point this at a scratch file; on the device it is the kernel's.
DROP_CACHES=${IOTGW_DROP_CACHES:-/proc/sys/vm/drop_caches}

# Written U-Boot first and config.txt last. A device whose config.txt still
# says kernel=u-boot.bin (set by older OTA hooks) keeps booting that file until
# the new config.txt, without that line, lands; by then kernel_2712.img is
# U-Boot. Every interrupted state therefore still boots U-Boot.
ARTIFACTS=(kernel_2712.img bcm2712-rpi-5-b.dtb config.txt)

RESTORE=""
ASSUME_YES=0
DRY_RUN=0
WRITES=0
PLANNED=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "${BACKUP_DIR}/${RUN_ID}" ] || RUN_ID="${RUN_ID}-$$"
RUN_DIR="${BACKUP_DIR}/${RUN_ID}"

log() { printf '[iotgw-rpi-bootfiles-update] %s\n' "$*"; }
die() { printf '[iotgw-rpi-bootfiles-update][ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

usage() {
    cat <<'EOF'
Usage:
  iotgw-rpi-bootfiles-update [--yes] [--dry-run]
  iotgw-rpi-bootfiles-update --restore <run-id> [--yes] [--dry-run]

Writes the staged U-Boot (kernel_2712.img), board DTB and config.txt to the FAT /boot after
verifying them against the manifest and checking that the new DTB still trusts
both installed slot FITs, backing up the current files and reading each back.
Reboot after a successful run.

Options:
  --yes               Non-interactive confirmation
  --restore <run-id>  Write back the backup of an earlier run (ls BACKUP_DIR)
  --dry-run           Print planned actions only; write nothing
  --help              Show this help

Environment overrides:
  ROOT_DIR=/usr/share/iotgw/rpi-boot  MANIFEST=$ROOT_DIR/manifest.tsv
  BOOT_MP=/boot  BACKUP_DIR=/data/rpi-boot/backup
EOF
}

finish() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "$1 dry-run complete: ${PLANNED} file(s) would be written; nothing written."
    elif [ "$WRITES" -eq 0 ]; then
        log "$1 complete: boot files already current; nothing written, no reboot needed."
    else
        log "$1 complete: ${WRITES} file(s) written. Reboot for the new boot files to take effect."
    fi
}

# manifest columns: artifact  sha256  size  boot_target
manifest_col() {
    awk -F'\t' -v n="$1" -v c="$2" 'NR==1{next} $1==n {print $c; exit}' "$MANIFEST"
}
sha_of()     { sha256sum "$1" | awk '{print $1}'; }
meta_get()   { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
free_bytes() { df -Pk "$BOOT_MP" 2>/dev/null | awk 'NR==2{print $4*1024}'; }

# check_anchor_compat <candidate-dtb>: refuse a DTB under which an installed
# slot FIT would not verify (iotgw-fit-anchor.sh).
check_anchor_compat() {
    local cand="$1" cur="${BOOT_MP}/${ANCHOR}" slot fit why
    [ -f "$cur" ] && [ "$(sha_of "$cand")" = "$(sha_of "$cur")" ] && return 0
    [ -f "$cur" ] || die "anchor guard: no current ${cur}; slot FIT signers cannot be identified"
    for slot in a b; do
        fit="${BOOT_MP}/fitImage-${slot}"
        if [ ! -f "$fit" ]; then
            log "anchor guard: no ${fit}; slot ${slot} not checked"
            continue
        fi
        why="$(fit_anchor_check "$fit" "$cur" "$cand")" \
            || die "anchor guard: slot ${slot} would not boot with the candidate ${ANCHOR}: ${why}; refusing"
        log "anchor guard: slot ${slot} FIT trusted by the candidate ${ANCHOR}"
    done
}

# check_config_kernel <config.txt>: the firmware must run U-Boot. A kernel=
# line may name only kernel_2712.img (written by this tool) or u-boot.bin.
check_config_kernel() {
    local k
    k="$(sed -n 's/^[[:space:]]*kernel[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$1" | tail -n1)"
    case "$k" in
        ""|kernel_2712.img|u-boot.bin) ;;
        *) die "config.txt names kernel=${k}; only U-Boot (kernel_2712.img or u-boot.bin) is supported; refusing" ;;
    esac
}

check_boot() {
    local line
    line=$(findmnt -no FSTYPE,OPTIONS "$BOOT_MP" 2>/dev/null) || die "$BOOT_MP is not a mount point"
    case "$line" in vfat*) ;; *) die "$BOOT_MP is not a FAT filesystem: $line" ;; esac
    case ",${line#* }," in *,rw,*) ;; *) die "$BOOT_MP is not mounted read-write: $line" ;; esac
}

# Save the current /boot/<target> (or record its absence) for --restore.
backup_file() {
    local target="$1" dst="${BOOT_MP}/$1"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN back up ${dst} -> ${RUN_DIR}/${target}"; return 0; }
    install -d -m 0700 "$RUN_DIR"
    if [ -f "$dst" ]; then
        cp -a "$dst" "${RUN_DIR}/${target}"; sync
        printf 'target\t%s\nsize\t%s\nsha256\t%s\npresent\t1\n' \
            "$target" "$(stat -c%s "${RUN_DIR}/${target}")" "$(sha_of "${RUN_DIR}/${target}")" \
            > "${RUN_DIR}/${target}.meta"
    else
        printf 'target\t%s\npresent\t0\n' "$target" > "${RUN_DIR}/${target}.meta"
    fi
    sync
    log "backed up ${target} -> ${RUN_DIR}/"
}

# Skip if current, check space, back up, atomic write, read back.
write_verify() {
    local src="$1" target="$2" expected="$3" dst="${BOOT_MP}/$2" size cur avail tmp read_hash
    size="$(stat -c%s "$src")"
    cur=""; [ -f "$dst" ] && cur="$(sha_of "$dst")"
    if [ "$cur" = "$expected" ]; then
        log "${target} already current on $BOOT_MP; skipping"; return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN would write ${target} (${size} B) to ${dst}"; PLANNED=$((PLANNED+1)); return 0
    fi
    avail="$(free_bytes)"
    [ -n "$avail" ] || die "cannot read free space on $BOOT_MP"
    [ "$size" -le "$avail" ] || die "${target} (${size} B) exceeds free space on $BOOT_MP (${avail} B)"
    backup_file "$target"
    tmp="${BOOT_MP}/.${target}.new"
    rm -f "$tmp"
    cp "$src" "$tmp"; sync
    # Dropped page cache: the hashes come from the FAT medium, not from the
    # pages just written. A bad copy is refused before it replaces the file.
    echo 3 > "$DROP_CACHES"
    [ "$(sha_of "$tmp")" = "$expected" ] \
        || { rm -f "$tmp"; die "copy of ${target} on $BOOT_MP failed verification; current file left in place"; }
    mv -f "$tmp" "$dst"; sync
    echo 3 > "$DROP_CACHES"
    read_hash="$(sha_of "$dst")"
    [ "$read_hash" = "$expected" ] \
        || die "readback mismatch for ${target} (written but verify failed: DO NOT REBOOT; re-run or --restore)"
    log "${target} written and verified"
    WRITES=$((WRITES+1))
}

do_update() {
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    check_boot
    local a src exp ans
    for a in "${ARTIFACTS[@]}"; do          # verify every artifact BEFORE any write
        src="${ROOT_DIR}/${a}"
        [ -f "$src" ] || die "staged artifact missing: $src"
        exp="$(manifest_col "$a" 2)"
        [ -n "$exp" ] || die "$a not in manifest"
        [ "$(sha_of "$src")" = "$exp" ] || die "$a artifact hash != manifest"
    done
    check_anchor_compat "${ROOT_DIR}/${ANCHOR}"
    check_config_kernel "${ROOT_DIR}/config.txt"
    log "boot-file update for ${BOOT_MP}$([ "$DRY_RUN" -eq 1 ] && echo ' (dry-run)')"
    for a in "${ARTIFACTS[@]}"; do log "  $a ($(manifest_col "$a" 2))"; done
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Proceed with the %s file update? [y/N]: ' "$BOOT_MP"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    for a in "${ARTIFACTS[@]}"; do
        write_verify "${ROOT_DIR}/${a}" "$a" "$(manifest_col "$a" 2)"
    done
    finish update
}

do_restore() {
    local dir="${BACKUP_DIR}/${RESTORE}" a meta ans
    [ -d "$dir" ] || die "no backup run '${RESTORE}' in ${BACKUP_DIR}"
    check_boot
    for a in "${ARTIFACTS[@]}"; do          # pre-verify the backup
        meta="${dir}/${a}.meta"; [ -f "$meta" ] || continue
        if [ "$(meta_get "$meta" present)" = "1" ]; then
            [ -f "${dir}/${a}" ] || die "backup ${RESTORE} lacks ${a}"
            [ "$(sha_of "${dir}/${a}")" = "$(meta_get "$meta" sha256)" ] || die "${a} backup hash != meta: corrupt"
        fi
    done
    meta="${dir}/${ANCHOR}.meta"
    if [ -f "$meta" ]; then
        [ "$(meta_get "$meta" present)" = "1" ] \
            || die "anchor guard: run ${RESTORE} would remove ${ANCHOR}, the FIT trust anchor; refusing"
        check_anchor_compat "${dir}/${ANCHOR}"
    fi
    if [ -f "${dir}/config.txt" ]; then
        check_config_kernel "${dir}/config.txt"
    fi
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Restore %s files from backup run %s? [y/N]: ' "$BOOT_MP" "$RESTORE"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    for a in "${ARTIFACTS[@]}"; do
        meta="${dir}/${a}.meta"; [ -f "$meta" ] || continue
        if [ "$(meta_get "$meta" present)" = "1" ]; then
            write_verify "${dir}/${a}" "$a" "$(meta_get "$meta" sha256)"
        elif [ "$DRY_RUN" -eq 0 ] && [ -f "${BOOT_MP}/${a}" ]; then
            log "restore: ${a} was absent in the backup; removing current"
            backup_file "$a"
            rm -f "${BOOT_MP:?}/${a}"; sync; WRITES=$((WRITES+1))
        fi
    done
    finish restore
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --restore) RESTORE="${2:-}"; [ -n "$RESTORE" ] || die "--restore needs a run id"; shift 2 ;;
            --yes)     ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [ "$(id -u)" -eq 0 ] || die "must run as root"
    for c in sha256sum awk stat findmnt df fdtget; do need_cmd "$c"; done
    # shellcheck source=iotgw-fit-anchor.sh
    . "$ANCHOR_LIB" || die "cannot load ${ANCHOR_LIB}"
    if [ -n "$RESTORE" ]; then do_restore; else do_update; fi
}

main "$@"
