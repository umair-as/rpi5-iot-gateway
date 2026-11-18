# shellcheck shell=bash
# FIT trust-anchor checks, sourced by iotgw-rauc-preinstall and
# iotgw-rpi-bootfiles-update.
#
# U-Boot verifies a slot FIT's configuration signature against the public
# keys in the board DTB (/boot/bcm2712-rpi-5-b.dtb, the trust anchor). A key
# takes part when it is marked required="conf". With /signature/required-mode
# "any", one valid signature by a required key is enough; without it (U-Boot's
# default, "all") the FIT must carry a valid signature by every required key.
#
# Keys are identified by the SHA-256 of their RSA modulus and exponent, never
# by name: two DTBs may hold different keys under the same name. A FIT names
# its signer only by key-name-hint, so the hint is resolved to a key through
# the DTB the device boots with today, the one whose keys verified the
# installed FITs.
#
# These checks show that a FIT will be accepted. They do not authenticate it:
# that is U-Boot's signature check at boot, and the RAUC bundle signature
# before any of this runs.

# fit_anchor_key_fp <dtb> <key-node>: fingerprint of the key, or nothing.
fit_anchor_key_fp() {
    fdtget -t x "$1" "/signature/$2" rsa,modulus >/dev/null 2>&1 || return 0
    { fdtget -t x "$1" "/signature/$2" rsa,modulus
      fdtget -t x "$1" "/signature/$2" rsa,exponent; } | sha256sum | awk '{print $1}'
}

# fit_anchor_required_fps <dtb>: fingerprints of its required="conf" keys.
fit_anchor_required_fps() {
    local k
    for k in $(fdtget -l "$1" /signature 2>/dev/null); do
        case "$k" in
            key-*)
                [ "$(fdtget "$1" "/signature/$k" required 2>/dev/null)" = conf ] || continue
                fit_anchor_key_fp "$1" "$k"
                ;;
        esac
    done
    return 0
}

# fit_anchor_mode <dtb>: "any" or "all" (U-Boot's default when unset).
fit_anchor_mode() {
    case "$(fdtget "$1" /signature required-mode 2>/dev/null)" in
        any) echo any ;;
        *) echo all ;;
    esac
}

# fit_anchor_signers <fit>: key-name-hint of each signature in the FIT's
# default configuration, the one U-Boot boots when no #conf is given.
fit_anchor_signers() {
    local conf s
    conf="$(fdtget "$1" /configurations default 2>/dev/null)" || return 0
    [ -n "$conf" ] || return 0
    for s in $(fdtget -l "$1" "/configurations/${conf}" 2>/dev/null); do
        case "$s" in
            signature*) fdtget "$1" "/configurations/${conf}/${s}" key-name-hint 2>/dev/null || true ;;
        esac
    done
    return 0
}

# fit_anchor_check <fit> <current-dtb> <candidate-dtb>
# Succeeds when U-Boot booting with <candidate-dtb> would accept <fit>.
# Prints the reason on failure. Signer hints are resolved through
# <current-dtb>; pass the same file twice to check a FIT against the anchor
# in use.
fit_anchor_check() {
    local fit="$1" cur="$2" cand="$3" mode trusted signers hint fp signed=""
    [ -f "$fit" ] || { echo "no FIT at ${fit}"; return 1; }
    [ -f "$cur" ] || { echo "no current anchor at ${cur}"; return 1; }
    [ -f "$cand" ] || { echo "no candidate anchor at ${cand}"; return 1; }
    trusted="$(fit_anchor_required_fps "$cand")"
    [ -n "$trusted" ] || { echo "anchor has no required=\"conf\" key; it would accept unsigned FITs"; return 1; }
    signers="$(fit_anchor_signers "$fit")"
    [ -n "$signers" ] || { echo "FIT default configuration carries no signature"; return 1; }
    for hint in $signers; do
        fp="$(fit_anchor_key_fp "$cur" "key-${hint}")"
        [ -n "$fp" ] || { echo "signer '${hint}' is not a key of the current anchor; its key cannot be identified"; return 1; }
        signed="${signed}${fp}"$'\n'
    done
    mode="$(fit_anchor_mode "$cand")"
    if [ "$mode" = any ]; then
        for fp in $signed; do
            printf '%s\n' "$trusted" | grep -qx "$fp" && return 0
        done
        echo "anchor (required-mode any) trusts none of the FIT's signers: ${signers//$'\n'/ }"
        return 1
    fi
    for fp in $trusted; do
        printf '%s' "$signed" | grep -qx "$fp" \
            || { echo "anchor (required-mode all) requires a key the FIT is not signed with (${fp:0:16}...)"; return 1; }
    done
    return 0
}
