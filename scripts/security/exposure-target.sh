#!/bin/bash
# Network-exposure assertions for the IoT Gateway distro (iotgw).
#
# Answers one question the rest of the smoke suite does not: is anything
# listening, or admitted by the firewall, on an address family or scope we did
# not intend?
#
# Why this exists. sshd on this image is one long-lived daemon (sshd.service,
# "sshd -D") that binds its own listener. Without an explicit scope it binds
# DUAL-STACK (*:22); with a global IPv6 address on any interface that makes SSH
# reachable over un-NATed IPv6. The scope lives in
# /etc/ssh/sshd_config.d/05-iotgw-listen.conf (AddressFamily inet,
# ListenAddress 0.0.0.0), and no build-time guard covers it: the image's listen
# guard only sees socket units.
#
# The first section asks sshd itself (sshd -T on the config it runs with) and
# then the kernel (ss): the config can be right while a stale or second
# listener is not, and the reverse.
#
# Usage:
#   # On target directly (with lib/target-check.sh copied to ../lib):
#   sudo ./exposure-target.sh
#
#   # From host over SSH (no copy needed):
#   cat scripts/lib/target-check.sh scripts/security/exposure-target.sh | ssh <gw> 'sudo bash -s'
#
#   # Via the runner:
#   scripts/run-target-checks.sh <device-ip> exposure
#
# Pairs with:
#   scripts/security/exposure-probe-host.sh - the off-device reachability
#     oracle. A device cannot prove its own external reachability; that check
#     must run from a second host.
#
# Environment overrides:
#   IOTGW_EXPECT_SSH_LISTEN  expected sshd listen address
#                            (default: 0.0.0.0:22)
#   IOTGW_LISTEN_ALLOWLIST   content of the listen allowlist (set by
#                            run-target-checks.sh from listen-allowlist.txt)
#   IOTGW_LISTEN_ALLOWLIST_FILE  path to it, when run on the target directly

set -u

# Reporting helpers: streamed ahead of this script by run-target-checks.sh,
# otherwise sourced from the repo layout.
if ! command -v say_pass >/dev/null 2>&1; then
    # shellcheck source=../lib/target-check.sh
    . "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../lib/target-check.sh" || exit 2
fi
# Read by say_skip in the shared helpers; this script's output is ASCII-only.
# shellcheck disable=SC2034
TC_SKIP_SEP=' - '

# Expected sshd listener. IPv4-only is deliberate: the listener itself
# enforces the family, rather than depending on a firewall rule staying correct.
EXPECT_SSH_LISTEN="${IOTGW_EXPECT_SSH_LISTEN:-0.0.0.0:22}"

# Expected listeners: scripts/security/listen-allowlist.txt (format in its
# header). The device has no copy of the repo, so run-target-checks.sh streams
# the file's content in IOTGW_LISTEN_ALLOWLIST ahead of this script; run on the
# target directly, it reads IOTGW_LISTEN_ALLOWLIST_FILE or a listen-allowlist.txt
# next to this script.
if [ -z "${IOTGW_LISTEN_ALLOWLIST:-}" ]; then
    _al_file="${IOTGW_LISTEN_ALLOWLIST_FILE:-$(dirname -- "${BASH_SOURCE[0]:-$0}")/listen-allowlist.txt}"
    [ -r "$_al_file" ] && IOTGW_LISTEN_ALLOWLIST=$(cat "$_al_file")
fi

# This image's short name (dev, desktop, prod, base) for the allowlist's
# images column: IMAGE_BASENAME in /etc/buildinfo, without the iot-gw-image-
# prefix.
AL_IMAGE=${IOTGW_IMAGE_OVERRIDE:-$(sed -n 's/^IMAGE_BASENAME=//p' /etc/buildinfo 2>/dev/null | tr -d '"')}
AL_IMAGE=${AL_IMAGE#iot-gw-image-}

# Active allowlist entries, one "proto pattern firewall domain" per element. A
# line applies when its gate unit is active (or the gate is "-") and, if it
# names images, this image is one of them. Missing optional columns read "-".
AL_ENTRIES=()
while read -r _gate _proto _pat _fw _dom _img _rest; do
    case "$_gate" in ''|'#'*) continue ;; esac
    if [ "$_gate" != "-" ]; then
        systemctl is-active --quiet "$_gate" 2>/dev/null || continue
    fi
    case "${_img:--}" in
        -) : ;;
        *) case ",$_img," in *",$AL_IMAGE,"*) : ;; *) continue ;; esac ;;
    esac
    AL_ENTRIES+=("$_proto $_pat $_fw ${_dom:--}")
done <<EOF
${IOTGW_LISTEN_ALLOWLIST:-}
EOF

# A pattern with no wildcard left once its escapes are removed is an exact
# address, and must be present.
al_is_exact() {
    local rest
    rest=$(printf '%s' "$1" | sed 's/\\.//g')
    case "$rest" in *[\*\?\[]*) return 1 ;; *) return 0 ;; esac
}

# "<firewall> <domain>" of the first active entry matching "<proto> <addr>",
# or nothing. The pattern is deliberately unquoted: it is a bash pattern.
al_match() {
    local proto="$1" addr="$2" e ep pat fw dom
    for e in "${AL_ENTRIES[@]}"; do
        read -r ep pat fw dom <<<"$e"
        [ "$ep" = "$proto" ] || continue
        # shellcheck disable=SC2254
        case "$addr" in $pat) printf '%s %s\n' "$fw" "$dom"; return 0 ;; esac
    done
    return 1
}

# SELinux types of the processes holding a listener, from the users:((...))
# field of `ss -p`, space separated and sorted; empty if none could be read.
pid_domain() { cut -d: -f3 "/proc/$1/attr/current" 2>/dev/null; }
listener_domains() {
    local pid
    for pid in $(printf '%s' "$1" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
        pid_domain "$pid"
    done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
section "sshd listen scope"
# The config sshd runs with: SSHD_OPTS in /etc/default/ssh (read-only rootfs
# sets -f /etc/ssh/sshd_config_readonly), quotes stripped.
sshd_cfg=$(sed -n 's/.*-f[[:space:]]*\([^ ]*\).*/\1/p' /etc/default/ssh 2>/dev/null | head -n1 | tr -d "'\"")
sshd_eff=$(sshd -T ${sshd_cfg:+-f "$sshd_cfg"} 2>/dev/null)
if [ -z "$sshd_eff" ]; then
    say_skip "sshd listen config" "sshd -T unavailable (not root, or sshd missing)"
else
    af=$(printf '%s\n' "$sshd_eff" | awk '$1=="addressfamily"{print $2}')
    la=$(printf '%s\n' "$sshd_eff" | awk '$1=="listenaddress"{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')
    printf '    sshd: addressfamily=%s listenaddress=%s\n' "${af:-?}" "${la:-?}"
    [ "$af" = inet ] && say_pass "sshd addressfamily=inet" \
        || say_fail "sshd addressfamily=${af:-?} (expected inet: 05-iotgw-listen.conf missing or overridden?)"
    [ "$la" = "$EXPECT_SSH_LISTEN" ] && say_pass "sshd listenaddress=$la" \
        || say_fail "sshd listenaddress='${la:-(empty)}', expected '$EXPECT_SSH_LISTEN'"
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet sshd.service \
        && say_pass "sshd.service active" || say_fail "sshd.service not active"
    # A socket-activated sshd next to the daemon would be a second, unpinned
    # listener on :22.
    if systemctl is-enabled --quiet sshd.socket 2>/dev/null \
       || systemctl is-active --quiet sshd.socket 2>/dev/null; then
        say_fail "sshd.socket is enabled/active beside sshd.service"
    fi
fi

# ---------------------------------------------------------------------------
section "listening socket inventory"
# Every listener, loopback included, must match an active allowlist entry; the
# entry's firewall expectation is checked against the live ruleset below.
LISTENER_FW=""   # "<port> <firewall> <proto> <addr>" lines for that section
if ! command -v ss >/dev/null 2>&1; then
    say_skip "listener inventory" "ss not available (iproute2-ss)"
elif [ "${#AL_ENTRIES[@]}" -eq 0 ]; then
    say_fail "no listen allowlist (IOTGW_LISTEN_ALLOWLIST empty and no listen-allowlist.txt)"
else
    unexpected=0
    seen=""
    # -H omits the header; field 4 is Local Address:Port for both -tln and -uln,
    # the rest (-p) names the owning processes, which needs root.
    while read -r proto laddr procs; do
        [ -z "$laddr" ] && continue
        seen="$seen $proto:$laddr"
        if m=$(al_match "$proto" "$laddr"); then
            read -r fw dom <<<"$m"
            say_pass "listener $proto $laddr (allowlisted, firewall $fw)"
            LISTENER_FW="${LISTENER_FW}${laddr##*:} $fw $proto $laddr
"
            if [ "$dom" != "-" ]; then
                got=$(listener_domains "$procs")
                if [ "$got" = "$dom" ]; then
                    say_pass "listener $proto $laddr runs in $dom"
                else
                    say_fail "listener $proto $laddr runs in '${got:-unknown (ss -p needs root)}', allowlist requires $dom"
                fi
            fi
        else
            say_fail "listener $proto $laddr is NOT in the allowlist"
            unexpected=$((unexpected + 1))
        fi
    done <<EOF
$( { ss -tlnpH 2>/dev/null | awk '{p=""; for (i=6; i<=NF; i++) p=p $i; print "tcp", $4, p}'
     ss -ulnpH 2>/dev/null | awk '{p=""; for (i=6; i<=NF; i++) p=p $i; print "udp", $4, p}'; } | sort -u )
EOF

    # A listener that VANISHED matters as much as one that appeared - a missing
    # service is a regression too, and a subset check would not notice.
    for e in "${AL_ENTRIES[@]}"; do
        read -r ep pat _fw _dom <<<"$e"
        al_is_exact "$pat" || continue
        want="$ep:$(printf '%s' "$pat" | sed 's/\\\(.\)/\1/g')"
        case " $seen " in
            *" $want "*) : ;;
            *) say_fail "expected listener ${want/:/ } is ABSENT" ;;
        esac
    done

    [ "$unexpected" -eq 0 ] && say_pass "no listeners outside the allowlist"
fi

# ---------------------------------------------------------------------------
section "firewall address-family qualification"
# Ports the input chain admits. Consumed by the IPv6 section below to verify
# that every wildcard v6 listener is in fact unreachable, rather than assuming
# it. Empty string means "could not determine" and the v6 section degrades to a
# SKIP rather than a false PASS.
FW_ACCEPT_PORTS=""
FW_SCOPED_PORTS=""
if ! command -v nft >/dev/null 2>&1; then
    say_skip "nftables ruleset" "nft not available"
else
    if nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
        say_pass "/etc/nftables.conf parses"
    else
        say_fail "/etc/nftables.conf does not parse"
    fi

    # In a "table inet", a rule such as "tcp dport 22 accept" with no family
    # qualifier matches BOTH IPv4 and IPv6. nft prints its own canonical form,
    # so a qualified rule appears as "meta nfproto ipv4 tcp dport 22 accept"
    # (or with a leading "ip "/"ip6 " match). Anything with a dport and no
    # family token is unqualified.
    chain=$(nft list chain inet filter input 2>/dev/null)
    if [ -z "$chain" ]; then
        say_skip "inet filter input" "chain not present"
    else
        FW_ACCEPT_PORTS=$(printf '%s\n' "$chain" \
            | grep -E 'dport .* accept' | grep -vE '\biifname\b' \
            | sed -E 's/.*dport[[:space:]]+\{?[[:space:]]*([0-9, ]+).*/\1/' \
            | tr ',' ' ' | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
        # Rules bound to an input interface (iifname) admit a port from ONE link
        # only; they are reported separately and do not count as off-link exposure.
        FW_SCOPED_PORTS=$(printf '%s\n' "$chain" \
            | grep -E 'dport .* accept' | grep -E '\biifname\b' \
            | sed -E 's/.*dport[[:space:]]+\{?[[:space:]]*([0-9, ]+).*/\1/' \
            | tr ',' ' ' | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')
        printf '    input chain admits ports: %s\n' "${FW_ACCEPT_PORTS:-(none)}"
        printf '    interface-scoped admits:  %s\n' "${FW_SCOPED_PORTS:-(none)}"

        unqualified=$(printf '%s\n' "$chain" \
            | grep -E 'dport' \
            | grep -vE 'nfproto (ipv4|ipv6)' \
            | grep -vE '(^|[[:space:]])ip6?[[:space:]]' || true)
        if [ -z "$unqualified" ]; then
            say_pass "all dport rules in inet filter input are family-qualified"
        else
            say_fail "unqualified dport rule(s) in inet filter input - these match IPv4 AND IPv6:"
            printf '%s\n' "$unqualified" | sed 's/^/        /'
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "listener / firewall pairing"
# The allowlist states what the firewall must do with each listener's port;
# compare that with the live input chain, so the bind and the rule cannot
# drift apart unnoticed.
if [ -z "$LISTENER_FW" ]; then
    say_skip "listener / firewall pairing" "no allowlisted listeners recorded"
elif [ -z "$FW_ACCEPT_PORTS$FW_SCOPED_PORTS" ] && [ -z "${chain:-}" ]; then
    say_skip "listener / firewall pairing" "input chain unknown"
else
    while read -r port fw proto laddr; do
        [ -z "$port" ] && continue
        in_open=0; in_scoped=0
        printf ' %s ' "$FW_ACCEPT_PORTS" | grep -q " $port " && in_open=1
        printf ' %s ' "${FW_SCOPED_PORTS:-}" | grep -q " $port " && in_scoped=1
        case "$fw" in
            open)
                [ "$in_open" -eq 1 ] && say_pass "$proto $laddr: port $port admitted (expected open)" \
                    || say_fail "$proto $laddr: port $port expected open, input chain does not admit it" ;;
            scoped)
                [ "$in_open" -eq 0 ] && say_pass "$proto $laddr: port $port not admitted network-wide" \
                    || say_fail "$proto $laddr: port $port admitted network-wide, expected interface-scoped at most" ;;
            closed)
                [ "$in_open" -eq 0 ] && [ "$in_scoped" -eq 0 ] && say_pass "$proto $laddr: port $port not admitted (expected closed)" \
                    || say_fail "$proto $laddr: port $port admitted by the input chain, expected closed" ;;
            *)
                say_fail "$proto $laddr: unknown firewall expectation '$fw' in the allowlist" ;;
        esac
    done <<EOF
$LISTENER_FW
EOF
fi

# ---------------------------------------------------------------------------
section "IPv6 reachability posture"
# Report the COUNT only. This output is meant to be pasteable into a commit
# body, and the repo is public - a global address identifies the site.
if ! command -v ip >/dev/null 2>&1; then
    say_skip "global IPv6 addresses" "ip not available"
else
    gua_count=$(ip -6 -o addr show scope global 2>/dev/null | wc -l)
    printf '    global IPv6 addresses: %s\n' "$gua_count"
    if [ "$gua_count" -eq 0 ]; then
        say_pass "no global IPv6 addresses - v6 exposure not reachable off-link"
    else
        # Not a failure by itself: OTBR border routing legitimately needs
        # infrastructure IPv6. It IS a failure if a service is bound v6-wide.
        v6_wide=$( { ss -tlnH; ss -ulnH; } 2>/dev/null | awk '{print $4}' \
            | grep -E '^\[::\]:' | sort -u || true)
        if [ -z "$v6_wide" ]; then
            say_pass "$gua_count global IPv6 address(es) present, but no wildcard v6 listeners"
        elif [ -z "$FW_ACCEPT_PORTS" ]; then
            say_skip "wildcard v6 listeners" \
                "firewall accept set unknown - cannot prove these are unreachable"
        else
            # A wildcard v6 bind is acceptable ONLY if the firewall does not
            # admit its port. Checking the listener against a static allowlist
            # would just re-encode the assumption; checking it against the LIVE
            # ruleset is what catches the two controls drifting apart - which is
            # exactly how SSH ended up reachable over IPv6.
            for l in $v6_wide; do
                lport="${l##*:}"
                if printf ' %s ' "$FW_ACCEPT_PORTS" | grep -q " $lport "; then
                    say_fail "wildcard v6 listener $l AND firewall admits port $lport, with $gua_count global IPv6 address(es) - reachable off-link"
                elif printf ' %s ' "${FW_SCOPED_PORTS:-}" | grep -q " $lport "; then
                    say_pass "wildcard v6 listener $l admitted only by interface-scoped rule(s) (not off-link)"
                else
                    say_pass "wildcard v6 listener $l is unreachable (firewall does not admit $lport)"
                fi
            done
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "D-Bus authorization (RAUC)"
# rauc.service runs as root and unsandboxed by necessity - it writes raw slot
# images. meta-rauc's shipped policy grants send_destination to
# context="default", so ANY local process could call InstallBundle or Mark:
# replace the rootfs, flip boot state, or roll back to an older still-signed
# bundle. Signature verification constrains what may be installed, not who may
# ask. This asserts the override in
# /etc/dbus-1/system.d/de.pengutronix.rauc-iotgw.conf is actually in force.
#
# Non-destructive by construction: the probe calls a method that DOES NOT EXIST.
# D-Bus evaluates policy before dispatch, so a blocked caller gets AccessDenied
# and an permitted caller gets UnknownMethod - nothing is ever executed.
if ! command -v busctl >/dev/null 2>&1; then
    say_skip "RAUC D-Bus authorization" "busctl not available"
elif ! busctl --system status de.pengutronix.rauc >/dev/null 2>&1 \
     && ! busctl --system list 2>/dev/null | grep -q de.pengutronix.rauc; then
    say_skip "RAUC D-Bus authorization" "rauc not present on the bus"
else
    # Test as a confined service account rather than 'nobody' - it represents
    # the actual threat: a compromised non-root service pivoting to root.
    probe_user=""
    for u in otbr nobody; do
        id "$u" >/dev/null 2>&1 && { probe_user="$u"; break; }
    done

    if [ -z "$probe_user" ]; then
        say_skip "RAUC D-Bus authorization" "no unprivileged account to probe with"
    else
        probe_out=$(su -s /bin/sh -c \
            "busctl --system call de.pengutronix.rauc / de.pengutronix.rauc.Installer IotgwPolicyProbe" \
            "$probe_user" 2>&1)

        # busctl's actual wording on this stack is "Call failed: Access denied"
        # (verified on-target), which is neither AccessDenied (no space) nor
        # "Permission denied" (different word). Matching only those two
        # earlier patterns turned a genuine, correct denial into an
        # "inconclusive" SKIP instead of a PASS.
        case "$probe_out" in
            *AccessDenied*|*[Aa]ccess\ denied*|*"not allowed"*|*[Pp]ermission\ denied*)
                say_pass "state-changing Installer call from '$probe_user' is DENIED by policy" ;;
            *UnknownMethod*|*"Unknown method"*|*"No such method"*)
                say_fail "'$probe_user' reached the Installer interface (got UnknownMethod, not AccessDenied) - any local process can call InstallBundle/Mark on a root service" ;;
            *)
                say_fail "RAUC D-Bus authorization: unrecognized busctl response, treating as unverified: ${probe_out%%$'\n'*}" ;;
        esac

        # The override must not break the legitimate readers: edge-healthd calls
        # GetSlotStatus, and denying it would silently break health reporting.
        if su -s /bin/sh -c \
            "busctl --system call de.pengutronix.rauc / de.pengutronix.rauc.Installer GetSlotStatus" \
            "$probe_user" >/dev/null 2>&1; then
            say_pass "read-only GetSlotStatus still permitted for '$probe_user' (edge-healthd path intact)"
        else
            say_fail "GetSlotStatus is denied for '$probe_user' - the policy is too tight and breaks edge-healthd health reporting"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "pre-authentication surface"
# Image tier from /etc/version (iot-gw-image-<tier>-...). Prod has stricter
# expectations; dev prints the same facts as INFO.
IMAGE_TIER="unknown"
case "$(cat /etc/version 2>/dev/null)" in
    *image-prod*) IMAGE_TIER=prod ;;
    *image-dev*)  IMAGE_TIER=dev ;;
    *image-base*) IMAGE_TIER=base ;;
    *image-desktop*) IMAGE_TIER=desktop ;;
esac
printf '    image tier: %s\n' "$IMAGE_TIER"

# sshd effective authentication policy, from the config resolved in the
# "sshd listen scope" section (sshd_cfg, sshd_eff).
if [ -z "$sshd_eff" ]; then
    say_skip "sshd effective auth policy" "sshd -T unavailable"
else
    pw=$(printf '%s\n' "$sshd_eff" | awk '$1=="passwordauthentication"{print $2}')
    kbd=$(printf '%s\n' "$sshd_eff" | awk '$1=="kbdinteractiveauthentication"{print $2}')
    root=$(printf '%s\n' "$sshd_eff" | awk '$1=="permitrootlogin"{print $2}')
    printf '    sshd: passwordauthentication=%s kbdinteractiveauthentication=%s permitrootlogin=%s\n' "$pw" "$kbd" "$root"
    [ "$root" = "prohibit-password" ] || [ "$root" = "without-password" ] || [ "$root" = "no" ] \
        && say_pass "root login is key-only ($root)" || say_fail "permitrootlogin=$root"
    # Key-only on every tier (99-iotgw.conf): the account hashes that ship in
    # the layer are for the console, sudo and newrole, never for the network.
    if [ "$pw" = no ] && [ "$kbd" = no ]; then
        say_pass "password and keyboard-interactive authentication off"
    else
        say_fail "password/keyboard-interactive authentication enabled (99-iotgw.conf overridden or missing?)"
    fi
    x11=$(printf '%s\n' "$sshd_eff" | awk '$1=="x11forwarding"{print $2}')
    [ "$x11" = no ] && say_pass "x11forwarding no" \
        || say_fail "x11forwarding=$x11 (openssh's x11 distro-feature sed reached the effective config)"
    if [ "$IMAGE_TIER" = prod ]; then
        [ -e /etc/ssh/sshd_config.d/10-iotgw-prod-auth.conf ] \
            && say_pass "prod sshd policy drop-in present" || say_fail "10-iotgw-prod-auth.conf missing"
        # No relaying through an authenticated session on the appliance.
        for kw in allowtcpforwarding allowstreamlocalforwarding allowagentforwarding permittunnel gatewayports; do
            v=$(printf '%s\n' "$sshd_eff" | awk -v k="$kw" '$1==k{print $2}')
            [ "$v" = no ] && say_pass "prod: $kw no" || say_fail "prod: $kw=$v (expected no: 10-iotgw-prod-auth.conf)"
        done
        mat=$(printf '%s\n' "$sshd_eff" | awk '$1=="maxauthtries"{print $2}')
        [ "$mat" = 3 ] && say_pass "prod: maxauthtries 3" || say_fail "prod: maxauthtries=$mat (expected 3)"
    fi
fi

# wpa_supplicant: no WPS/P2P code, no P2P device, bounded capabilities.
wpa_bin=$(command -v wpa_supplicant 2>/dev/null || echo /usr/sbin/wpa_supplicant)
if [ -x "$wpa_bin" ]; then
    # Control-interface command names exist in the binary only when the feature
    # is compiled in; grep -a works on busybox too.
    # grep -c prints the count (0 included) and exits 1 on no match: no fallback.
    n_wps=$(grep -a -c 'WPS_PBC\|WPS_PIN' "$wpa_bin" 2>/dev/null); n_wps=${n_wps:-0}
    n_p2p=$(grep -a -c 'P2P_FIND\|P2P_CONNECT' "$wpa_bin" 2>/dev/null); n_p2p=${n_p2p:-0}
    [ "$n_wps" -eq 0 ] && say_pass "wpa_supplicant built without WPS" \
        || say_fail "wpa_supplicant has WPS compiled in ($n_wps command strings) - upstream defconfig, not iotgw-wpa_supplicant.config"
    [ "$n_p2p" -eq 0 ] && say_pass "wpa_supplicant built without P2P" \
        || say_fail "wpa_supplicant has P2P compiled in ($n_p2p command strings)"
    if command -v iw >/dev/null 2>&1 && iw dev 2>/dev/null | grep -q 'type P2P-device'; then
        say_fail "a P2P-device interface is live (answers P2P probes from any peer in range)"
    else
        say_pass "no P2P-device interface"
    fi
    for u in $(systemctl list-units --type=service --state=active --no-legend 'wpa_supplicant@*' 2>/dev/null | awk '{print $1}'); do
        caps=$(systemctl show "$u" -p CapabilityBoundingSet --value 2>/dev/null)
        case " $caps " in
            *" cap_sys_admin "*|*" cap_sys_module "*|*" cap_setuid "*)
                say_fail "$u capability bounding set still includes sys_admin/sys_module/setuid (hardening drop-in not applied)" ;;
            *) say_pass "$u capability bounding set: ${caps:-(empty)}" ;;
        esac
        score=$(systemd-analyze security --no-pager "$u" 2>/dev/null | sed -n 's/.*: \([0-9.]*\) .*/\1/p' | tail -n1)
        if [ -n "$score" ]; then
            printf '    %s systemd exposure score: %s\n' "$u" "$score"
            awk -v s="$score" 'BEGIN{exit !(s+0 <= 5.0)}' && say_pass "$u exposure score $score <= 5.0" \
                || say_fail "$u exposure score $score > 5.0"
        fi
    done
else
    say_skip "wpa_supplicant checks" "binary not present"
fi

# prod hygiene: dev-only content must be absent.
if [ "$IMAGE_TIER" = prod ]; then
    leak=""
    for f in /usr/bin/node /usr/share/otbr-webui /usr/bin/nmap /usr/bin/iperf3 /usr/bin/gdb /usr/bin/strace \
             /usr/bin/tcpdump /usr/bin/wireshark /etc/sysctl.d/95-iotgw-crash-debug.conf /home/devel; do
        [ -e "$f" ] && leak="$leak $f"
    done
    [ -z "$leak" ] && say_pass "prod: no dev-only files present" || say_fail "prod: dev-only content present:$leak"
    if command -v nft >/dev/null 2>&1 && nft list chain inet filter input 2>/dev/null | grep -qE 'dport[[:space:]]+80[[:space:]]'; then
        say_fail "prod: firewall admits tcp/80 (OTBR web UI rule)"
    else
        say_pass "prod: tcp/80 not admitted"
    fi
fi

# ---------------------------------------------------------------------------
section "hardening baseline present (all tiers)"
# packagegroup-iot-gw-security is a base-image property (iot-gw-image-base.inc)
# and the prod build gate checks it; this is the on-target half of the same
# assertion, for every tier.
WIFI_IFACE="${IOTGW_WIFI_IFACE:-wlan0}"
missing=""
for f in /etc/sysctl.d/99-iotgw-hardening.conf /etc/modprobe.d/iotgw-blacklist.conf \
         /etc/systemd/system/wpa_supplicant@"$WIFI_IFACE".service.d/override.conf \
         /etc/systemd/system/systemd-networkd.service.d/override.conf \
         /etc/systemd/system/tmp.mount.d/override.conf \
         /etc/audit/rules.d/iotgw.rules; do
    [ -e "$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && say_pass "hardening files present (sysctl, blacklist, drop-ins, audit rules)" \
    || say_fail "hardening content missing (packagegroup-iot-gw-security not in this image?):$missing"
# Functional: the sysctl must have been applied, not only shipped.
kptr=$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo "?")
[ "$kptr" = 2 ] && say_pass "kernel.kptr_restrict=2 (99-iotgw-hardening.conf applied)" \
    || say_fail "kernel.kptr_restrict=$kptr (expected 2; hardening sysctl not applied)"
# Functional: auditd loaded our rules and locked them to the tier's policy
# (IOTGW_AUDIT_RULE_IMMUTABLE: dev 1 = enabled, prod 2 = immutable until reboot).
if command -v auditctl >/dev/null 2>&1; then
    aen=$(auditctl -s 2>/dev/null | awk '/^enabled/ {print $2}')
    case "$IMAGE_TIER:$aen" in
        prod:2) say_pass "audit enabled=2 (rules loaded and immutable)" ;;
        prod:*) say_fail "audit enabled=${aen:-?} on prod (expected 2: iotgw.rules not loaded or not locked)" ;;
        *:1|*:2) say_pass "audit enabled=$aen (rules loaded)" ;;
        *) say_fail "audit enabled=${aen:-?} (expected 1 or 2: iotgw.rules not loaded)" ;;
    esac
else
    say_skip "audit status" "auditctl not installed"
fi

# ---------------------------------------------------------------------------
section "forwarding policy"
# The kernel forwards between every interface (ip_forward is on for the
# Thread border router), so the forward chain is what keeps one attached
# network from routing through the gateway into another. Policy drop, no
# unconditional accept, and every accept either conntrack-scoped or naming an
# explicit interface pair; the only pair allowed is Thread (wpan0) <-> the
# OTBR infrastructure interface, and only when OTBR is on this image.
OTBR_INFRA_IFACE="${IOTGW_OTBR_INFRA_IFACE:-$(sed -n 's/.* -B \([^ "]*\).*/\1/p' /etc/default/otbr-agent 2>/dev/null)}"
OTBR_INFRA_IFACE="${OTBR_INFRA_IFACE:-wlan0}"
otbr_present=0
command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files 'otbr-agent.service' 2>/dev/null | grep -q '\.service' && otbr_present=1
if ! command -v nft >/dev/null 2>&1; then
    say_skip "forward chain" "nft not available"
else
    fchain=$(nft list chain inet filter forward 2>/dev/null)
    if [ -z "$fchain" ]; then
        say_fail "inet filter forward chain not present (ruleset not loaded?)"
    else
        printf '%s\n' "$fchain" | grep -qE 'policy drop' \
            && say_pass "forward chain policy drop" || say_fail "forward chain policy is not drop"
        # nft prints one rule per line, indented; a rule that is just "accept"
        # admits everything and makes the policy dead.
        if printf '%s\n' "$fchain" | grep -qE '^[[:space:]]+accept([[:space:]]|$)'; then
            say_fail "forward chain has an unconditional accept (open router)"
        else
            say_pass "forward chain has no unconditional accept"
        fi
        # Every accept must be conntrack-scoped or name an interface pair.
        loose=$(printf '%s\n' "$fchain" | grep -E '[[:space:]]accept([[:space:]]|$)' \
            | grep -vE '^[[:space:]]+ct state' \
            | grep -vE 'iifname "[^"]+" oifname (!= )?"[^"]+"' || true)
        [ -z "$loose" ] && say_pass "every forward accept is conntrack- or interface-pair-scoped" \
            || { say_fail "forward accept rule(s) without a ct state or interface pair:"; printf '%s\n' "$loose" | sed 's/^/        /'; }
        # "oifname != X" is recorded as <iif>>any: Thread egress leaves through
        # whichever link has the default route.
        pairs=$(printf '%s\n' "$fchain" | grep -E 'iifname "[^"]+" oifname (!= )?"[^"]+".*accept' \
            | sed -E 's/.*iifname "([^"]+)" oifname != "[^"]+".*/\1>any/; s/.*iifname "([^"]+)" oifname "([^"]+)".*/\1>\2/' | sort -u | tr '\n' ' ')
        printf '    forwarded interface pairs: %s\n' "${pairs:-(none)}"
        if [ "$otbr_present" = 1 ]; then
            case " $pairs " in
                *" wpan0>$OTBR_INFRA_IFACE "*|*" wpan0>any "*) say_pass "Thread -> $OTBR_INFRA_IFACE forwarding admitted (OTBR)" ;;
                *) say_fail "OTBR present but wpan0 -> $OTBR_INFRA_IFACE forwarding is not admitted (Thread egress/NAT64 broken)" ;;
            esac
            case " $pairs " in
                *" $OTBR_INFRA_IFACE>wpan0 "*) say_pass "$OTBR_INFRA_IFACE -> Thread forwarding admitted (OTBR)" ;;
                *) say_fail "OTBR present but $OTBR_INFRA_IFACE -> wpan0 forwarding is not admitted" ;;
            esac
        fi
        for pr in $pairs; do
            case "$pr" in
                wpan0\>"$OTBR_INFRA_IFACE"|wpan0\>any|"$OTBR_INFRA_IFACE"\>wpan0)
                    [ "$otbr_present" = 1 ] || say_fail "OTBR forwarding pair $pr admitted on an image without otbr-agent" ;;
                *) say_fail "unexpected forwarded interface pair $pr (only Thread <-> infrastructure is allowed)" ;;
            esac
        done
    fi
fi
# Active probe: forward a packet through the gateway from a throwaway
# network namespace and expect it to be dropped; then admit that one pair
# with a temporary rule and expect it to pass, which proves the first result
# came from the firewall and not from a missing route. Everything created is
# removed on exit. IOTGW_FORWARD_PROBE=0 disables it.
if [ "${IOTGW_FORWARD_PROBE:-1}" != 1 ]; then
    say_skip "forward probe" "disabled (IOTGW_FORWARD_PROBE=0)"
elif [ "$(id -u)" != 0 ] || ! command -v ip >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
    say_skip "forward probe" "needs root, ip and nft"
else
    egress_if=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    egress_gw=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}')
    if [ -z "$egress_if" ] || [ -z "$egress_gw" ]; then
        say_skip "forward probe" "no IPv4 default route to forward toward"
    else
        PROBE_NS=iotgw-fwprobe
        PROBE_IF=fwprobe0
        probe_cleanup() {
            nft delete table ip iotgw_fwprobe_nat 2>/dev/null || true
            ip link del "$PROBE_IF" 2>/dev/null || true
            ip netns del "$PROBE_NS" 2>/dev/null || true
        }
        probe_cleanup
        trap probe_cleanup EXIT
        if ip netns add "$PROBE_NS" 2>/dev/null \
           && ip link add "$PROBE_IF" type veth peer name fwprobe1 netns "$PROBE_NS" 2>/dev/null \
           && ip addr add 10.255.254.1/30 dev "$PROBE_IF" && ip link set "$PROBE_IF" up \
           && ip -n "$PROBE_NS" addr add 10.255.254.2/30 dev fwprobe1 \
           && ip -n "$PROBE_NS" link set fwprobe1 up && ip -n "$PROBE_NS" link set lo up \
           && ip -n "$PROBE_NS" route add default via 10.255.254.1; then
            printf '    probe: %s -> gateway -> %s (%s)\n' "$PROBE_NS" "$egress_if" "$egress_gw"
            if ip netns exec "$PROBE_NS" ping -c 2 -W 1 "$egress_gw" >/dev/null 2>&1; then
                say_fail "forward probe: packets from $PROBE_IF were forwarded out $egress_if (cross-interface forwarding not blocked)"
            else
                say_pass "forward probe: $PROBE_IF -> $egress_if forwarding rejected"
            fi
            # Admit this one pair in the baseline chain (an accept in any
            # other table's forward chain could not help: this chain's drop is
            # final), plus source NAT so the reply can come back, and expect
            # the same probe to succeed.
            nft add rule inet filter forward iifname "$PROBE_IF" oifname "$egress_if" accept 2>/dev/null
            nft -f - <<EOF >/dev/null 2>&1
table ip iotgw_fwprobe_nat {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr 10.255.254.0/30 oifname "$egress_if" masquerade
  }
}
EOF
            if ip netns exec "$PROBE_NS" ping -c 2 -W 2 "$egress_gw" >/dev/null 2>&1; then
                say_pass "forward probe: the same path passes once its interface pair is admitted (drop above was the firewall)"
            else
                say_skip "forward probe control" "admitted path still gets no reply from $egress_gw (gateway not answering ICMP?) - the rejection above is not attributable"
            fi
            # Remove the temporary accept from the baseline chain by handle.
            h=$(nft -a list chain inet filter forward 2>/dev/null \
                | grep -E "iifname \"$PROBE_IF\" oifname \"$egress_if\" accept" | sed -E 's/.*# handle ([0-9]+).*/\1/' | head -n1)
            [ -n "$h" ] && nft delete rule inet filter forward handle "$h" 2>/dev/null
            probe_cleanup
            trap - EXIT
            nft list chain inet filter forward 2>/dev/null | grep -q "\"$PROBE_IF\"" \
                && say_fail "forward probe: temporary rule left in the baseline chain" \
                || say_pass "forward probe: temporary rules and namespace removed"
        else
            probe_cleanup; trap - EXIT
            say_skip "forward probe" "could not set up the probe namespace (netns/veth unsupported or SELinux?)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "firewall unit: early and fail-closed"
if ! command -v systemctl >/dev/null 2>&1; then
    say_skip "iotgw-nftables.service" "systemctl not available"
else
    systemctl is-active --quiet iotgw-nftables.service \
        && say_pass "iotgw-nftables.service active" || say_fail "iotgw-nftables.service not active"
    before=$(systemctl show -p Before --value iotgw-nftables.service 2>/dev/null)
    for want in network-pre.target sshd.service; do
        case " $before " in
            *" $want "*) say_pass "iotgw-nftables.service orders before $want" ;;
            *) say_fail "iotgw-nftables.service does not order before $want (Before=$before)" ;;
        esac
    done
    systemctl show -p ExecStopPost --value iotgw-nftables.service 2>/dev/null | grep -q iotgw-nftables-fallback \
        && say_pass "fail-closed fallback hooked (ExecStopPost=iotgw-nftables-fallback)" \
        || say_fail "no fail-closed fallback on iotgw-nftables.service"
    # The two timestamps answer "was the ruleset in before sshd listened?":
    # both are monotonic microseconds since boot.
    t_fw=$(systemctl show -p ExecMainExitTimestampMonotonic --value iotgw-nftables.service 2>/dev/null)
    t_ssh=$(systemctl show -p ExecMainStartTimestampMonotonic --value sshd.service 2>/dev/null)
    if [ -n "$t_fw" ] && [ -n "$t_ssh" ] && [ "$t_fw" -gt 0 ] && [ "$t_ssh" -gt 0 ]; then
        [ "$t_fw" -le "$t_ssh" ] && say_pass "ruleset loaded before sshd started (fw ${t_fw}us <= sshd ${t_ssh}us)" \
            || say_fail "sshd started before the ruleset was loaded (sshd ${t_ssh}us < fw ${t_fw}us)"
    else
        say_skip "ruleset-before-sshd timing" "timestamps unavailable"
    fi
fi

# ---------------------------------------------------------------------------
section "runtime kernel knobs (99-iotgw-hardening.conf)"
# Values that must hold on every tier. With sysrq_always_enabled on the command
# line the kernel reports kernel.sysrq as 1 whatever the sysctl holds
# (sysrq_mask()), so 1 is expected there and the command line is checked next.
sysrq_want=0
grep -qw sysrq_always_enabled=1 /proc/cmdline 2>/dev/null && sysrq_want=1
for kv in kernel.sysrq=$sysrq_want kernel.kexec_load_disabled=1 kernel.yama.ptrace_scope=1 kernel.kptr_restrict=2 kernel.dmesg_restrict=1; do
    k=${kv%%=*}; want=${kv#*=}
    got=$(sysctl -n "$k" 2>/dev/null || echo "?")
    [ "$got" = "$want" ] && say_pass "$k=$got" || say_fail "$k=$got (expected $want)"
done
if grep -qw sysrq_always_enabled=1 /proc/cmdline 2>/dev/null; then
    [ "$IMAGE_TIER" = prod ] && say_fail "prod: sysrq_always_enabled=1 on the kernel command line (crash-debug profile leaked)" \
        || printf '    info: sysrq_always_enabled=1 on the command line (crash-debug profile; SysRq live despite kernel.sysrq=0)\n'
else
    say_pass "no sysrq_always_enabled on the kernel command line"
fi
if [ -r /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    kc=$(zcat /proc/config.gz 2>/dev/null)
    printf '%s\n' "$kc" | grep -q '^CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0$' \
        && say_pass "CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0" || say_fail "CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE is not 0x0 (security-prod.cfg not applied?)"
    if [ "$IMAGE_TIER" = prod ]; then
        if printf '%s\n' "$kc" | grep -q '^CONFIG_SECURITY_SELINUX_DEVELOP=y$'; then
            say_fail "prod: CONFIG_SECURITY_SELINUX_DEVELOP=y (runtime switch to permissive)"
        else
            say_pass "prod: no runtime switch to permissive"
        fi
        # Markers that only a dev fragment can set: FTRACE is explicitly unset
        # in the arm64 defconfig (observability-dev.cfg turns it on),
        # DYNAMIC_DEBUG defaults to n with no selector (debug-crash-dev.cfg),
        # PSTORE_FTRACE needs FUNCTION_TRACER (debug-crash-dev.cfg),
        # DEBUG_INFO_BTF has no selector (btf-core-dev.cfg). Options the
        # defconfig itself enables (BPF_SYSCALL, MAGIC_SYSRQ, KPROBES via
        # selectors) are deliberately not used as markers.
        for opt in CONFIG_FTRACE CONFIG_DYNAMIC_DEBUG CONFIG_PSTORE_FTRACE CONFIG_DEBUG_INFO_BTF; do
            printf '%s\n' "$kc" | grep -q "^$opt=y$" \
                && say_fail "prod kernel has $opt=y (dev observability/crash-debug/BTF fragment leaked)" \
                || say_pass "prod kernel: $opt not set"
        done
    fi
else
    say_skip "kernel config" "/proc/config.gz not readable"
fi

# ---------------------------------------------------------------------------
section "external reachability"
say_skip "off-device reachability" \
    "a device cannot prove its own external reachability - run scripts/security/exposure-probe-host.sh from a second host"

# ---------------------------------------------------------------------------
summary
