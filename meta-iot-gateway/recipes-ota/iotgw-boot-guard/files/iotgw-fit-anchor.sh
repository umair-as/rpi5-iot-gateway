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
# Keys are identified by the SHA-256 of every property U-Boot verifies with
# (algo, rsa,num-bits, rsa,n0-inverse, rsa,modulus, rsa,exponent,
# rsa,r-squared), never by name: two DTBs may hold different keys under the
# same name, or the same modulus with a different encoding. A FIT names its
# signer only by key-name-hint, so the hint is resolved to a key through the
# DTB the device boots with today, the one whose keys verified the installed
# FITs.
#
# Limitation: no signature is verified here. A hint is an unsigned label, so a
# FIT signed by another key under a known hint, or carrying a corrupt
# signature next to a valid one, is counted as signed by the named key. That
# is why fit_anchor_preserves exists: an anchor change that could narrow trust
# must be shown safe with U-Boot's verifier on the build host first.
#
# These checks show that a FIT will be accepted. They do not authenticate it:
# that is U-Boot's signature check at boot, and the RAUC bundle signature
# before any of this runs.

# fit_anchor_key_fp <dtb> <key-node>: fingerprint of the key, or nothing when
# the node lacks any property U-Boot verifies with.
fit_anchor_key_fp() {
    local p v out=""
    v="$(fdtget "$1" "/signature/$2" algo 2>/dev/null)" || return 0
    out="algo ${v}"$'\n'
    for p in rsa,num-bits rsa,n0-inverse rsa,modulus rsa,exponent rsa,r-squared; do
        v="$(fdtget -t x "$1" "/signature/$2" "$p" 2>/dev/null)" || return 0
        out="${out}${p} ${v}"$'\n'
    done
    printf '%s' "$out" | sha256sum | awk '{print $1}'
}

# fit_anchor_required_fps <dtb>: fingerprints of its required="conf" keys,
# deduplicated. U-Boot counts every /signature subnode marked required, so a
# required node that cannot be fingerprinted is printed as UNPARSEABLE:<node>,
# which no FIT signer matches and fit_anchor_preserves refuses.
fit_anchor_required_fps() {
    local k fp
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        [ "$(fdtget "$1" "/signature/$k" required 2>/dev/null)" = conf ] || continue
        fp="$(fit_anchor_key_fp "$1" "$k")"
        echo "${fp:-UNPARSEABLE:${k}}"
    done <<< "$(fdtget -l "$1" /signature 2>/dev/null)" | sort -u
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
    while IFS= read -r hint; do
        [ -n "$hint" ] || continue
        fp="$(fit_anchor_key_fp "$cur" "key-${hint}")"
        [ -n "$fp" ] || { echo "signer '${hint}' is not a key of the current anchor; its key cannot be identified"; return 1; }
        signed="${signed}${fp}"$'\n'
    done <<< "$signers"
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

# fit_anchor_preserves <current-dtb> <candidate-dtb>
# Succeeds when every FIT the current anchor accepts is accepted by the
# candidate too, from the anchors alone (R = required keys):
#   candidate any, current any: R(current) is a subset of R(candidate);
#   candidate any, current all: R(current) and R(candidate) share a key;
#   candidate all: R(candidate) is a subset of R(current), and the current
#                  anchor is "all".
# With a single required key, any and all are the same and count as any.
# Anything else narrows trust; the reason is printed.
fit_anchor_preserves() {
    local cur="$1" cand="$2" rc rn mc mn fp
    rc="$(fit_anchor_required_fps "$cur")"
    rn="$(fit_anchor_required_fps "$cand")"
    [ -n "$rn" ] || { echo "candidate has no required=\"conf\" key"; return 1; }
    [ -n "$rc" ] || { echo "current anchor has no required=\"conf\" key to compare with"; return 1; }
    case "${rc}"$'\n'"${rn}" in
        *UNPARSEABLE:*) echo "a required key node cannot be fingerprinted (missing algo or rsa,* property)"; return 1 ;;
    esac
    mc=any; [ "$(printf '%s\n' "$rc" | grep -c .)" -eq 1 ] || mc="$(fit_anchor_mode "$cur")"
    mn=any; [ "$(printf '%s\n' "$rn" | grep -c .)" -eq 1 ] || mn="$(fit_anchor_mode "$cand")"
    if [ "$mn" = any ] && [ "$mc" = all ]; then
        for fp in $rc; do
            printf '%s\n' "$rn" | grep -qx "$fp" && return 0
        done
        echo "candidate keeps none of the keys the current anchor requires"
        return 1
    fi
    if [ "$mn" = any ]; then
        for fp in $rc; do
            printf '%s\n' "$rn" | grep -qx "$fp" \
                || { echo "candidate drops required key ${fp:0:16}..."; return 1; }
        done
        return 0
    fi
    for fp in $rn; do
        printf '%s\n' "$rc" | grep -qx "$fp" \
            || { echo "candidate (required-mode all) requires key ${fp:0:16}... that the current anchor does not"; return 1; }
    done
    [ "$mc" = all ] \
        || { echo "candidate changes required-mode from any to all"; return 1; }
    return 0
}
