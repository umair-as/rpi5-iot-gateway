# shellcheck shell=sh
# /etc/profile.d/iotgw-motd-dynamic.sh — sourced by interactive login
# shells (local TTY or SSH) after the static /etc/motd, /etc/issue, or
# /etc/issue.net has been shown by login(1)/agetty/sshd.
#
# Prints a small dynamic appendix with live system state. Designed to
# cost well under 50 ms: procfs/sysfs reads plus one `ip route get`.
# No D-Bus calls, no `rauc` CLI — the boot critical chain stays clean
# and login stays cheap. Live fields render in the reader's own
# process, so no generator service or refresh hook exists to go stale.
#
# Source-of-truth choices (why these, not the obvious alternative):
#   RAUC slot     : parsed from /proc/cmdline (`rauc.slot=A` is set by
#                   U-Boot's iotgw_set_bootargs). Zero IPC vs the
#                   `busctl get-property … BootSlot` D-Bus roundtrip.
#                   Slot health/OTA state are ops queries — use
#                   `rauc status` for those.
#   Primary IP    : `ip -4 route get 1.1.1.1` — the source address the
#                   kernel would use for default-route egress; the
#                   address to reach this gateway on a multi-NIC setup.
#   Uptime        : computed from /proc/uptime (busybox `uptime` lacks
#                   the `-p` pretty flag and would emit nothing).

# Only emit for interactive shells.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac

# Resilient reads — individual failures don't abort the login.
_iotgw_motd_render() {
    _kernel=$(uname -r 2>/dev/null || echo unknown)

    _booted=unknown
    if [ -r /proc/uptime ]; then
        _s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        if [ -n "$_s" ]; then
            _d=$(( _s / 86400 ))
            _h=$(( (_s % 86400) / 3600 ))
            _m=$(( (_s % 3600) / 60 ))
            if [ "$_d" -gt 0 ]; then
                _booted=$(printf '%dd %dh %dm' "$_d" "$_h" "$_m")
            elif [ "$_h" -gt 0 ]; then
                _booted=$(printf '%dh %dm' "$_h" "$_m")
            else
                _booted=$(printf '%dm' "$_m")
            fi
        fi
    fi

    _load=unknown
    if [ -r /proc/loadavg ]; then
        _load=$(awk '{printf "%s, %s, %s", $1, $2, $3}' /proc/loadavg)
    fi

    _mem_total="?" _mem_avail="?"
    if [ -r /proc/meminfo ]; then
        _mem_total=$(awk '/MemTotal:/ {printf "%.1f GB", $2/1024/1024; exit}' /proc/meminfo)
        _mem_avail=$(awk '/MemAvailable:/ {printf "%.1f GB", $2/1024/1024; exit}' /proc/meminfo)
    fi

    # Primary = default-route source address; others = remaining
    # global-scope IPv4 addresses. POSIX sed, not gawk match().
    _ip="not assigned" _if=""
    if command -v ip >/dev/null 2>&1; then
        _rt=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
        if [ -n "$_rt" ]; then
            _ip=$(printf '%s\n' "$_rt" | sed -nE 's/.*src ([0-9.]+).*/\1/p')
            _if=$(printf '%s\n' "$_rt" | sed -nE 's/.*dev ([^ ]+).*/\1/p')
            [ -n "$_ip" ] || _ip="not assigned"
        fi
        _others=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk -v skip="$_ip" '$4 !~ "^"skip"/" {sub("/.*","",$4); printf "%s (%s)  ", $4, $2}')
    fi

    _slot=external
    if [ -r /proc/cmdline ]; then
        _v=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null \
             | sed -nE 's/^rauc\.slot=(.+)$/\1/p' | head -1)
        [ -n "$_v" ] && _slot=$_v
    fi

    printf '\033[0;36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '    \033[0;33mKernel:      \033[0m%s\n' "$_kernel"
    printf '    \033[0;33mUptime:      \033[0m%s\n' "$_booted"
    printf '    \033[0;33mLoad:        \033[0m%s\n' "$_load"
    printf '    \033[0;33mMemory:      \033[0m%s available / %s total\n' "$_mem_avail" "$_mem_total"
    if [ -n "$_if" ]; then
        printf '    \033[0;33mPrimary IP:  \033[0m%s (%s)\n' "$_ip" "$_if"
    else
        printf '    \033[0;33mPrimary IP:  \033[0m%s\n' "$_ip"
    fi
    if [ -n "${_others:-}" ]; then
        printf '    \033[0;33mOther IPs:   \033[0m%s\n' "$_others"
    fi
    printf '    \033[0;33mRAUC slot:   \033[0m\033[1;32m%s\033[0m\n' "$_slot"
    printf '\033[0;36m  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '\n'

    unset _kernel _booted _load _mem_total _mem_avail _ip _if _rt _others _slot _v _s _d _h _m
}

_iotgw_motd_render
unset -f _iotgw_motd_render
