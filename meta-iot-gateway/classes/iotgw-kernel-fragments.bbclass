# Shared IoT Gateway kernel fragment policy for all kernel providers.
#
# IOTGW_KERNEL_FRAGMENTS is the single source of truth for which fragments
# are expected in ${UNPACKDIR}/fragments/.  SRC_URI is derived from it, so
# the two lists cannot drift.  do_configure:append enforces the invariant
# in both directions:
#   - every fragment named here must exist (fetch failure guard)
#   - every .cfg present in the workdir must be named here (stale-residue guard)
#
# Recipes that add their own unconditional fragments (e.g. thermal-rpi5.cfg)
# must pair the SRC_URI:append with a matching IOTGW_KERNEL_FRAGMENTS:append
# so the guard stays consistent.

# Gate Raspberry Pi firmware RTC support for providers that carry the backport.
IOTGW_ENABLE_RPI_RTC ?= "1"

# Gate Raspberry Pi EEPROM tooling stack (shared with packagegroup gating).
IOTGW_ENABLE_RPI_EEPROM ?= "1"

# Gate VCIO mailbox chardev (/dev/vcio) needed by vcgencmd and rpi-eeprom-update.
# Default follows EEPROM tooling gate; developers can override independently.
IOTGW_ENABLE_VCIO ?= "${IOTGW_ENABLE_RPI_EEPROM}"

# ---------------------------------------------------------------------------
# Base fragments — always applied.
# ---------------------------------------------------------------------------
IOTGW_KERNEL_FRAGMENTS = "branding.cfg trim.cfg \
    storage-filesystems.cfg ikconfig.cfg \
    audit.cfg panic-recovery.cfg nftables-only.cfg"

# panic-on-oops.cfg is gated so dev builds can disable CONFIG_PANIC_ON_OOPS
# (default-on) from kas/local.yml without source edits.
IOTGW_KERNEL_FRAGMENTS += "${@'panic-on-oops.cfg' if d.getVar('IOTGW_ENABLE_PANIC_ON_OOPS') == '1' else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'rtc-rpi.cfg' if d.getVar('IOTGW_ENABLE_RPI_RTC') == '1' else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'vcio-rpi.cfg' if d.getVar('IOTGW_ENABLE_VCIO') == '1' else ''}"

# Optional fragments toggled via IOTGW_KERNEL_FEATURES (space/comma-separated).
IOTGW_KERNEL_FRAGMENTS += "${@'compute-media.cfg' if 'igw_compute_media' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
# Runtime root dm-verity: the kernel builds the verity root device itself from
# the signed boot arguments, which needs DM_INIT. Scoped to the feature so the
# default kernel configuration is unchanged.
IOTGW_KERNEL_FRAGMENTS += "${@'rootfs-verity.cfg' if 'igw_rootfs_verity' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'containers-cgroups.cfg' if 'igw_containers' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'networking-iot.cfg' if 'igw_networking_iot' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'observability-dev.cfg' if 'igw_observability_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'btf-core-dev.cfg' if 'igw_btf_core_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'pstore-persist.cfg' if 'igw_pstore_persist' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'debug-crash-dev.cfg' if 'igw_crash_debug_dev' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'security-prod.cfg' if 'igw_security_prod' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'selinux-locked.cfg' if 'igw_selinux_locked' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'tpm-slb9672.cfg' if 'igw_tpm_slb9672' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'efi-surface-reduction.cfg' if 'igw_no_efi' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'ima.cfg' if 'igw_ima' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_FRAGMENTS += "${@'desktop.cfg' if 'igw_desktop' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
# DX-M1 accelerator: no exported-symbol trimming, so the out-of-tree NPU driver
# links against the full export set. Scoped to the feature so every image
# without the accelerator keeps TRIM_UNUSED_KSYMS. Must stay LAST: fragments
# merge in list order and security-prod.cfg turns the trim on.
IOTGW_KERNEL_FRAGMENTS += "${@'deepx-dxm1-ksyms.cfg' if 'igw_deepx_dxm1' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Expected final values per feature, checked against the final .config after
# the merge. The fragment gate only checks the LAST request per symbol, so a
# fragment ordered wrongly passes it; these assertions do not depend on order.
# Format: CONFIG_<SYM>=<value>, where "n" means "is not set".
IOTGW_KERNEL_EXPECT ?= ""
IOTGW_KERNEL_EXPECT += "${@'CONFIG_TRIM_UNUSED_KSYMS=n CONFIG_MODULE_SIG_FORCE=y' if 'igw_deepx_dxm1' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_EXPECT += "${@'CONFIG_TRIM_UNUSED_KSYMS=y' if 'igw_security_prod' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() and 'igw_deepx_dxm1' not in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"
IOTGW_KERNEL_EXPECT += "${@'CONFIG_SECURITY_SELINUX_DEVELOP=n' if 'igw_selinux_locked' in (d.getVar('IOTGW_KERNEL_FEATURES') or '').replace(',', ' ').split() else ''}"

# Derive SRC_URI from IOTGW_KERNEL_FRAGMENTS so the two lists cannot diverge.
# Use :append (expansion-time) — kernel providers reset SRC_URI with `=`
# inside the recipe body, which would wipe out a parse-time `+=`.
SRC_URI:append = " ${@' '.join('file://fragments/' + f for f in (d.getVar('IOTGW_KERNEL_FRAGMENTS') or '').split() if f)}"

# Fragment-honoured gate: every request in the merged layer fragments must hold
# in the final .config. kconfig drops a requested value without error when a
# dependency is off (e.g. a platform trim removing the only selector of a
# framework), so the request stays in the fragment while the feature vanishes.
# For each symbol only the last request in merge order counts; "=n", "# ... is
# not set" and absence are the same. Prints one line per unmet request and
# returns 1. kernel-yocto's do_kernel_configcheck cannot serve here (see
# linux-iotgw-mainline-common.inc).
# usage: iotgw_fragment_gate <final .config> <fragment>...
iotgw_fragment_gate() {
    awk -v cfgfile="$1" '
        function shown(v) { return v == "" ? "not set" : v }
        FILENAME == cfgfile {
            if ($0 ~ /^CONFIG_[A-Za-z0-9_]+=/) {
                i = index($0, "=")
                got[substr($0, 1, i - 1)] = substr($0, i + 1)
            }
            next
        }
        /^CONFIG_[A-Za-z0-9_]+=/ {
            i = index($0, "=")
            s = substr($0, 1, i - 1)
            v = substr($0, i + 1)
            sub(/[ \t]+$/, "", v)
            if (v == "n") v = ""
            req[s] = v
            src[s] = FILENAME
            next
        }
        /^# CONFIG_[A-Za-z0-9_]+ is not set[ \t]*$/ {
            req[$2] = ""
            src[$2] = FILENAME
            next
        }
        END {
            bad = 0
            for (s in req) {
                g = (s in got) ? got[s] : ""
                if (g != req[s]) {
                    n = split(src[s], parts, "/")
                    printf "%s: %s requested %s, final %s\n", parts[n], s, shown(req[s]), shown(g)
                    bad = 1
                }
            }
            exit bad
        }
    ' "$@"
}

# Merge tracked fragments into the active kernel .config.
# Two invariants are enforced via bbfatal to catch regressions immediately:
#   1. Every fragment in IOTGW_KERNEL_FRAGMENTS must be present in the workdir.
#   2. No .cfg file in ${UNPACKDIR}/fragments/ may exist outside IOTGW_KERNEL_FRAGMENTS
#      — this is the stale-residue guard that prevents leftover files from a
#      previous build with different gates from silently altering the config.
do_configure:append() {
    # Build the allowed set and the ordered merge list from IOTGW_KERNEL_FRAGMENTS.
    tracked="${IOTGW_KERNEL_FRAGMENTS}"
    frags=
    for fname in $tracked; do
        fpath="${UNPACKDIR}/fragments/$fname"
        if [ ! -f "$fpath" ]; then
            bbfatal "iotgw-kernel-fragments: expected fragment missing: $fpath (check SRC_URI fetch)"
        fi
        frags="$frags $fpath"
    done

    # Stale-residue guard: reject any .cfg not in the tracked list.
    if [ -d "${UNPACKDIR}/fragments" ]; then
        for present in "${UNPACKDIR}/fragments/"*.cfg; do
            [ -f "$present" ] || continue
            bname=$(basename "$present")
            found=0
            for fname in $tracked; do
                if [ "$bname" = "$fname" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" = "0" ]; then
                bbfatal "iotgw-kernel-fragments: stale fragment not in IOTGW_KERNEL_FRAGMENTS: $present -- cleansstate the recipe and rebuild"
            fi
        done
    fi

    if [ -n "$frags" ] && [ -x "${S}/scripts/kconfig/merge_config.sh" ]; then
        oe_runmake -C ${S} O=${B} olddefconfig
        ${S}/scripts/kconfig/merge_config.sh -m -O ${B} ${B}/.config $frags || die "merge_config failed"
        oe_runmake -C ${S} O=${B} olddefconfig
    fi

    if [ -n "$frags" ]; then
        if ! unmet=$(iotgw_fragment_gate "${B}/.config" $frags); then
            bbfatal "iotgw-kernel-fragments: fragment requests not honoured by the final .config (a dependency is off or a later fragment overrides it):
$unmet"
        fi
        bbnote "iotgw-kernel-fragments: every request in $(echo $frags | wc -w) fragments holds in the final .config"
    fi

    failed=""
    for want in ${IOTGW_KERNEL_EXPECT}; do
        sym=${want%%=*}
        val=${want#*=}
        if [ "$val" = "n" ]; then
            if grep -q "^$sym=" ${B}/.config; then
                failed="$failed $sym: want not set, got $(grep "^$sym=" ${B}/.config | cut -d= -f2)"
            fi
        elif ! grep -qx "$sym=$val" ${B}/.config; then
            failed="$failed $sym: want $val, got $(grep "^$sym=" ${B}/.config | cut -d= -f2)"
        fi
    done
    if [ -n "$failed" ]; then
        bbfatal "iotgw-kernel-fragments: expected final config values not met:$failed"
    fi
}
