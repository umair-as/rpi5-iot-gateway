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
# Every check runs before the first write. Then all three current files, and
# a reference hash of /boot/u-boot.bin, are copied to a snapshot under /data,
# which is marked COMPLETE only once every copy is synced. Each file is
# copied to a temporary name, synced, read back from the medium, renamed over
# the target and read back again. FAT has no journal: a power cut during the
# rename leaves the target old or new, possibly with lost clusters that
# fsck.vfat repairs at the next boot.
# --restore <run-id> writes a COMPLETE snapshot back through the same guards,
# after snapshotting the current files in turn.
#
# Two layouts are supported, told apart by the kernel config.txt selects:
#   current  kernel_2712.img is U-Boot (no kernel= line, or kernel_2712.img)
#   legacy   kernel=u-boot.bin; kernel_2712.img holds Linux (older OTA hooks)
# The write order keeps U-Boot selected through every interrupted state:
#   target current: kernel_2712.img, DTB, config.txt. kernel_2712.img becomes
#                   U-Boot before config.txt stops selecting u-boot.bin.
#   target legacy:  config.txt, kernel_2712.img, DTB. config.txt selects
#                   u-boot.bin before kernel_2712.img stops being U-Boot.
# These guards check FIT trust and boot selection. They do not show that a
# given U-Boot and firmware DTB work together, nor FAT durability on power loss.
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

ARTIFACTS=(kernel_2712.img bcm2712-rpi-5-b.dtb config.txt)
SNAPSHOT_FORMAT=1

RESTORE=""
ASSUME_YES=0
ALLOW_TRUST_REDUCTION=0
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
  iotgw-rpi-bootfiles-update [--yes] [--dry-run] [--allow-trust-reduction]
  iotgw-rpi-bootfiles-update --restore <run-id> [--yes] [--dry-run] [--allow-trust-reduction]

Writes the staged U-Boot (kernel_2712.img), board DTB and config.txt to the FAT /boot after
verifying them against the manifest and checking that the new DTB still trusts
both installed slot FITs, backing up the current files and reading each back.
Reboot after a successful run.

Options:
  --yes               Non-interactive confirmation
  --restore <run-id>  Write back the snapshot of an earlier run (ls BACKUP_DIR)
  --allow-trust-reduction
                      Accept a DTB that drops a required FIT key or changes
                      required-mode to "all". First verify both slot FITs
                      against the new DTB on the build host:
                        sign_fit.py verify --fit <fitImage-x> --dtb <new dtb>
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
    local cand="$1" cur="${BOOT_MP}/${ANCHOR}" slot fit why=""
    [ -f "$cur" ] && [ "$(sha_of "$cand")" = "$(sha_of "$cur")" ] && return 0
    [ -f "$cur" ] || die "anchor guard: no current ${cur}; slot FIT signers cannot be identified"
    if ! why="$(fit_anchor_preserves "$cur" "$cand")"; then
        [ "$ALLOW_TRUST_REDUCTION" -eq 1 ] \
            || die "anchor guard: the candidate ${ANCHOR} narrows FIT trust (${why}). The on-device check cannot verify signatures; verify both slot FITs against it with sign_fit.py verify on the build host, then rerun with --allow-trust-reduction; refusing"
        log "anchor guard: candidate narrows FIT trust (${why}); accepted by --allow-trust-reduction"
    fi
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

# config_kernel <config.txt|-absent->: print the file the firmware runs, after
# refusing config.txt syntax this tool does not model: include, os_prefix, and
# kernel= under a conditional section other than [all] or [pi5]. The last
# applicable kernel= wins; none (or no config.txt) means kernel_2712.img.
config_kernel() {
    local k
    if [ "$1" = -absent- ]; then echo kernel_2712.img; return 0; fi
    k="$(awk '
        { line = $0; sub(/\r$/, "", line); sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
        line == "" { next }
        line ~ /^\[/ { sec = (line == "[all]" || line == "[pi5]") ? "" : line; next }
        line ~ /^include[ \t]/ { err = "!include"; exit }
        line ~ /^os_prefix[ \t]*=/ { err = "!os_prefix"; exit }
        line ~ /^kernel[ \t]*=/ {
            v = line; sub(/^kernel[ \t]*=[ \t]*/, "", v)
            if (sec != "") { err = "!section " sec; exit }
            k = v
        }
        END { if (err != "") print err; else if (k != "") print k }
    ' "$1")"
    case "$k" in
        "") echo kernel_2712.img ;;
        kernel_2712.img|u-boot.bin) echo "$k" ;;
        "!include") die "config.txt uses include; unsupported, refusing" ;;
        "!os_prefix") die "config.txt sets os_prefix; unsupported, refusing" ;;
        "!section "*) die "config.txt sets kernel= under ${k#!section }; unsupported, refusing" ;;
        *) die "config.txt names kernel=${k}; only U-Boot (kernel_2712.img or u-boot.bin) is supported; refusing" ;;
    esac
}

# write_order <kernel the target config.txt selects>: see the header.
write_order() {
    case "$1" in
        u-boot.bin) printf '%s\n' config.txt kernel_2712.img bcm2712-rpi-5-b.dtb ;;
        *)          printf '%s\n' kernel_2712.img bcm2712-rpi-5-b.dtb config.txt ;;
    esac
}

check_boot() {
    local line
    line=$(findmnt -no FSTYPE,OPTIONS "$BOOT_MP" 2>/dev/null) || die "$BOOT_MP is not a mount point"
    case "$line" in vfat*) ;; *) die "$BOOT_MP is not a FAT filesystem: $line" ;; esac
    case ",${line#* }," in *,rw,*) ;; *) die "$BOOT_MP is not mounted read-write: $line" ;; esac
}

# record_file <name> <src> <dir>: copy <src> to <dir>/<name> (or record its
# absence) with a .meta of size and hash.
record_file() {
    local name="$1" src="$2" dir="$3" h
    if [ -f "$src" ]; then
        h="$(sha_of "$src")"
        cp -a "$src" "${dir}/${name}"
        sync; echo 3 > "$DROP_CACHES"
        [ "$(sha_of "${dir}/${name}")" = "$h" ] || die "snapshot copy of ${name} does not match ${src}; nothing written to ${BOOT_MP}"
        printf 'target\t%s\nsize\t%s\nsha256\t%s\npresent\t1\n' \
            "$name" "$(stat -c%s "${dir}/${name}")" "$h" > "${dir}/${name}.meta"
    else
        printf 'target\t%s\npresent\t0\n' "$name" > "${dir}/${name}.meta"
    fi
}

# snapshot: save every current boot file, and a reference hash of u-boot.bin
# (not restored; a legacy restore needs it unchanged), then mark the run
# COMPLETE. Only a COMPLETE run can be restored.
snapshot() {
    local a ub="${BOOT_MP}/u-boot.bin"
    [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN snapshot ${BOOT_MP} -> ${RUN_DIR}"; return 0; }
    install -d -m 0700 "$RUN_DIR"
    for a in "${ARTIFACTS[@]}"; do record_file "$a" "${BOOT_MP}/${a}" "$RUN_DIR"; done
    if [ -f "$ub" ]; then
        printf 'present\t1\nsha256\t%s\n' "$(sha_of "$ub")" > "${RUN_DIR}/u-boot.bin.ref"
    else
        printf 'present\t0\n' > "${RUN_DIR}/u-boot.bin.ref"
    fi
    sync
    printf 'format\t%s\n' "$SNAPSHOT_FORMAT" > "${RUN_DIR}/COMPLETE"
    sync
    log "snapshot of ${BOOT_MP} -> ${RUN_DIR}/"
}

# Skip if current, check space, atomic write, read back.
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
    local a src exp ans changed kern
    for a in "${ARTIFACTS[@]}"; do          # verify every artifact BEFORE any write
        src="${ROOT_DIR}/${a}"
        [ -f "$src" ] || die "staged artifact missing: $src"
        exp="$(manifest_col "$a" 2)"
        [ -n "$exp" ] || die "$a not in manifest"
        [ "$(sha_of "$src")" = "$exp" ] || die "$a artifact hash != manifest"
    done
    check_anchor_compat "${ROOT_DIR}/${ANCHOR}"
    kern="$(config_kernel "${ROOT_DIR}/config.txt")"
    [ "$kern" = kernel_2712.img ] \
        || die "staged config.txt selects u-boot.bin; an update must boot the staged U-Boot (kernel_2712.img); refusing"
    log "boot-file update for ${BOOT_MP}$([ "$DRY_RUN" -eq 1 ] && echo ' (dry-run)')"
    for a in "${ARTIFACTS[@]}"; do log "  $a ($(manifest_col "$a" 2))"; done
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Proceed with the %s file update? [y/N]: ' "$BOOT_MP"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    changed=0
    for a in "${ARTIFACTS[@]}"; do
        [ -f "${BOOT_MP}/${a}" ] && [ "$(sha_of "${BOOT_MP}/${a}")" = "$(manifest_col "$a" 2)" ] || changed=1
    done
    [ "$changed" -eq 0 ] || snapshot
    for a in $(write_order kernel_2712.img); do
        write_verify "${ROOT_DIR}/${a}" "$a" "$(manifest_col "$a" 2)"
    done
    finish update
}

do_restore() {
    local dir="${BACKUP_DIR}/${RESTORE}" a meta ans cfg kern ub changed=0
    case "$RESTORE" in */*|.|..) die "run id '${RESTORE}' is not a plain name (ls ${BACKUP_DIR})" ;; esac
    [ -d "$dir" ] || die "no backup run '${RESTORE}' in ${BACKUP_DIR}"
    check_boot
    [ "$(meta_get "${dir}/COMPLETE" format 2>/dev/null)" = "$SNAPSHOT_FORMAT" ] \
        || die "run ${RESTORE} is not a COMPLETE snapshot (interrupted, or from an older version of this tool); refusing"
    for a in "${ARTIFACTS[@]}"; do          # pre-verify the snapshot
        meta="${dir}/${a}.meta"
        [ -f "$meta" ] || die "snapshot ${RESTORE} has no record of ${a}; refusing"
        case "$(meta_get "$meta" present)" in
            1) [ -f "${dir}/${a}" ] || die "snapshot ${RESTORE} lacks ${a}"
               [ "$(sha_of "${dir}/${a}")" = "$(meta_get "$meta" sha256)" ] || die "${a} snapshot hash != meta: corrupt" ;;
            0) ;;
            *) die "snapshot ${RESTORE}: malformed record of ${a}" ;;
        esac
    done
    case "$(meta_get "${dir}/u-boot.bin.ref" present 2>/dev/null || true)" in
        0|1) ;;
        *) die "snapshot ${RESTORE} has no record of u-boot.bin; refusing" ;;
    esac
    [ "$(meta_get "${dir}/${ANCHOR}.meta" present)" = "1" ] \
        || die "anchor guard: run ${RESTORE} would remove ${ANCHOR}, the FIT trust anchor; refusing"
    check_anchor_compat "${dir}/${ANCHOR}"
    cfg=-absent-; [ "$(meta_get "${dir}/config.txt.meta" present)" = "1" ] && cfg="${dir}/config.txt"
    kern="$(config_kernel "$cfg")"
    [ "$(meta_get "${dir}/kernel_2712.img.meta" present)" = "1" ] || [ "$kern" = u-boot.bin ] \
        || die "snapshot ${RESTORE} would boot kernel_2712.img but has none; refusing"
    if [ "$kern" = u-boot.bin ]; then
        ub="$(meta_get "${dir}/u-boot.bin.ref" sha256 2>/dev/null || true)"
        [ -n "$ub" ] || die "snapshot ${RESTORE} boots u-boot.bin but recorded none; refusing"
        [ -f "${BOOT_MP}/u-boot.bin" ] && [ "$(sha_of "${BOOT_MP}/u-boot.bin")" = "$ub" ] \
            || die "snapshot ${RESTORE} boots u-boot.bin, which is missing or changed since; refusing"
    fi
    for a in "${ARTIFACTS[@]}"; do
        if [ "$(meta_get "${dir}/${a}.meta" present)" = "1" ]; then
            [ -f "${BOOT_MP}/${a}" ] && [ "$(sha_of "${BOOT_MP}/${a}")" = "$(meta_get "${dir}/${a}.meta" sha256)" ] || changed=1
        else
            [ ! -f "${BOOT_MP}/${a}" ] || changed=1
        fi
    done
    if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        printf 'Restore %s files from snapshot %s? [y/N]: ' "$BOOT_MP" "$RESTORE"; read -r ans
        case "$ans" in y|Y) : ;; *) die "aborted by operator" ;; esac
    fi
    [ "$changed" -eq 0 ] || snapshot
    for a in $(write_order "$kern"); do
        if [ "$(meta_get "${dir}/${a}.meta" present)" = "1" ]; then
            write_verify "${dir}/${a}" "$a" "$(meta_get "${dir}/${a}.meta" sha256)"
        elif [ -f "${BOOT_MP}/${a}" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "DRY-RUN would remove ${BOOT_MP}/${a} (absent in the snapshot)"; PLANNED=$((PLANNED+1))
            else
                log "restore: ${a} was absent in the snapshot; removing current"
                rm -f "${BOOT_MP:?}/${a}"; sync; WRITES=$((WRITES+1))
            fi
        fi
    done
    finish restore
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --restore) RESTORE="${2:-}"; [ -n "$RESTORE" ] || die "--restore needs a run id"; shift 2 ;;
            --yes)     ASSUME_YES=1; shift ;;
            --allow-trust-reduction) ALLOW_TRUST_REDUCTION=1; shift ;;
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
