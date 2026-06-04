#!/bin/bash
# IoT Gateway dynamic banner generator.
#
# Renders three surfaces:
#   /etc/issue      -- TTY pre-login, ANSI colors. Read by agetty.
#   /etc/issue.net  -- SSH pre-login banner. Read by sshd (Banner directive).
#   /etc/motd       -- post-login on local TTY only. Printed by /bin/login
#                      (login.shadow) via MOTD_FILE in /etc/login.defs --
#                      no PAM involvement. SSH post-login does NOT show motd
#                      on this image (sshd PrintMotd=no, sshd built without
#                      libpam, no shell init prints motd).
#
# Generated once at boot by iotgw-banner.service, then refreshed by the
# NetworkManager dispatcher at /etc/NetworkManager/dispatcher.d/50-iotgw-banner
# on interface up/down and DHCP lease changes so IP fields stay current.

set -u

# Build-time substitutions performed by do_install in the recipe.
DISTRO_NAME="@DISTRO_NAME@"
DISTRO_VERSION="@DISTRO_VERSION@"
MACHINE="@MACHINE@"

ISSUE_FILE="${IOTGW_BANNER_ISSUE_FILE:-/etc/issue}"
ISSUE_NET_FILE="${IOTGW_BANNER_ISSUE_NET_FILE:-/etc/issue.net}"
MOTD_FILE="${IOTGW_BANNER_MOTD_FILE:-/etc/motd}"

rauc_dbus_get_string_property() {
    local prop="$1"
    busctl --system get-property \
        de.pengutronix.rauc \
        / \
        de.pengutronix.rauc.Installer \
        "$prop" 2>/dev/null | sed -nE 's/^[^ ]+ "(.*)"$/\1/p'
}

get_system_info() {
    KERNEL=$(uname -r 2>/dev/null || echo "unknown")

    # Boot time as ISO-8601 UTC. Honest in a static snapshot file
    # (the previous "Uptime: 0 minutes" was misleading -- the value was
    # captured at boot when uptime really was ~0).
    LAST_BOOTED=$(date -u -d "$(uptime -s 2>/dev/null)" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "unknown")

    # Primary IPv4 = source address the kernel would use for default-route
    # egress. Answers "what should I ssh to" on a multi-NIC box.
    PRIMARY_IP=""
    PRIMARY_IF=""
    if command -v ip >/dev/null 2>&1; then
        local rt
        rt=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1)
        PRIMARY_IP=$(printf '%s\n' "$rt" | awk 'match($0,/src ([0-9.]+)/,m){print m[1]; exit}')
        PRIMARY_IF=$(printf '%s\n' "$rt" | awk 'match($0,/dev ([^ ]+)/,m){print m[1]; exit}')
    fi

    # All other global-scope IPv4 addresses, interface-labelled, one per line.
    OTHER_IPS=""
    if command -v ip >/dev/null 2>&1; then
        OTHER_IPS=$(ip -4 -o addr show scope global up 2>/dev/null | \
            awk -v primary="$PRIMARY_IP" '{
                split($4, a, "/")
                if (a[1] != primary) printf "%s (%s)\n", a[1], $2
            }')
    fi

    # RAUC booted slot: prefer dbus, fall back to rauc-status CLI parse.
    if command -v busctl >/dev/null 2>&1; then
        RAUC_SLOT="$(rauc_dbus_get_string_property BootSlot || true)"
        RAUC_OP="$(rauc_dbus_get_string_property Operation || true)"
        RAUC_LAST_ERROR="$(rauc_dbus_get_string_property LastError || true)"
    fi
    [ -n "${RAUC_SLOT:-}" ] || RAUC_SLOT=$(rauc status 2>/dev/null | awk '/Booted from:/{print $3; exit}' || echo "unknown")
    [ -n "${RAUC_OP:-}" ] || RAUC_OP="unknown"
    [ -n "${RAUC_LAST_ERROR:-}" ] || RAUC_LAST_ERROR="none"

    # Boot status of the booted slot (good/bad/?) -- ANSI-stripped parse of
    # rauc-status text output. Empty if rauc isn't present.
    RAUC_STATUS=""
    if command -v rauc >/dev/null 2>&1; then
        RAUC_STATUS=$(rauc status 2>/dev/null | awk '
            /booted/ {found=1; next}
            found && /boot status:/ {
                gsub(/\033\[[0-9;]*m/, "")
                print $NF; exit
            }')
    fi
    [ -n "${RAUC_STATUS:-}" ] || RAUC_STATUS="?"
}

emit_ips_ansi() {
    if [ -n "${PRIMARY_IP}" ]; then
        printf "\033[0;33mPrimary IP:\033[0m %s (%s)\n" "${PRIMARY_IP}" "${PRIMARY_IF}"
    else
        printf "\033[0;33mPrimary IP:\033[0m not assigned\n"
    fi
    [ -n "${OTHER_IPS}" ] || return 0
    local first=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$first" = "1" ]; then
            printf "\033[0;33mOther IPs:\033[0m  %s\n" "$line"
            first=0
        else
            printf "            %s\n" "$line"
        fi
    done <<EOF
${OTHER_IPS}
EOF
}

emit_ips_plain() {
    if [ -n "${PRIMARY_IP}" ]; then
        printf "Primary IP: %s (%s)\n" "${PRIMARY_IP}" "${PRIMARY_IF}"
    else
        printf "Primary IP: not assigned\n"
    fi
    [ -n "${OTHER_IPS}" ] || return 0
    local first=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$first" = "1" ]; then
            printf "Other IPs:  %s\n" "$line"
            first=0
        else
            printf "            %s\n" "$line"
        fi
    done <<EOF
${OTHER_IPS}
EOF
}

generate_issue() {
    {
        printf "\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\033[1;33m                              ℹ Authorized users only\033[0m\n"
        printf "\033[0;37mThis device is intended for authorized use. Connections may be logged to\n"
        printf "help ensure reliability and security. If you weren't expecting access,\n"
        printf "please disconnect and contact the administrator.\033[0m\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\n"
        printf "\033[1;36m%s\033[0m  \033[0;37m%s\033[0m\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "\033[0;33mMachine:\033[0m %s    \033[0;33mSlot:\033[0m %s (%s)\n" \
            "${MACHINE}" "${RAUC_SLOT}" "${RAUC_STATUS}"
        printf "\033[0;33mKernel:\033[0m  %s\n" "${KERNEL}"
        printf "\n"
        emit_ips_ansi
        printf "\n"
        # \l is an agetty escape; expanded to the tty name at prompt time.
        printf "\033[0;33mTTY:\033[0m \\l\n"
        printf "\n"
    } > "${ISSUE_FILE}"
}

generate_issue_net() {
    {
        printf "\n"
        printf "================================================================================\n"
        printf "                        Authorized users only\n"
        printf "\n"
        printf "This device is intended for authorized use. Connections may be logged to\n"
        printf "support operations and security. If you weren't expecting access, please\n"
        printf "disconnect and contact the administrator.\n"
        printf "================================================================================\n"
        printf "\n"
        printf "%s  %s\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "Machine: %s    Slot: %s (%s)\n" "${MACHINE}" "${RAUC_SLOT}" "${RAUC_STATUS}"
        printf "Kernel:  %s\n" "${KERNEL}"
        printf "\n"
        emit_ips_plain
        printf "\n"
    } > "${ISSUE_NET_FILE}"
}

generate_motd() {
    {
        printf "\n"
        printf "\033[1;36m    ██╗ ██████╗ ████████╗     ██████╗  █████╗ ████████╗███████╗██╗    ██╗ █████╗ ██╗   ██╗\033[0m\n"
        printf "\033[1;36m    ██║██╔═══██╗╚══██╔══╝    ██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝██║    ██║██╔══██╗╚██╗ ██╔╝\033[0m\n"
        printf "\033[1;34m    ██║██║   ██║   ██║       ██║  ███╗███████║   ██║   █████╗  ██║ █╗ ██║███████║ ╚████╔╝\033[0m\n"
        printf "\033[1;34m    ██║██║   ██║   ██║       ██║   ██║██╔══██║   ██║   ██╔══╝  ██║███╗██║██╔══██║  ╚██╔╝\033[0m\n"
        printf "\033[0;34m    ██║╚██████╔╝   ██║       ╚██████╔╝██║  ██║   ██║   ███████╗╚███╔███╔╝██║  ██║   ██║\033[0m\n"
        printf "\033[0;34m    ╚═╝ ╚═════╝    ╚═╝        ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝\033[0m\n"
        printf "\n"
        printf "\033[1;37m    Welcome to %s %s\033[0m\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "\n"
        printf "    \033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "    \033[0;33mPlatform:\033[0m     %s\n" "${MACHINE}"
        printf "    \033[0;33mKernel:\033[0m       %s\n" "${KERNEL}"
        printf "    \033[0;33mLast booted:\033[0m  %s\n" "${LAST_BOOTED}"
        if [ -n "${PRIMARY_IP}" ]; then
            printf "    \033[0;33mPrimary IP:\033[0m   %s (%s)\n" "${PRIMARY_IP}" "${PRIMARY_IF}"
        else
            printf "    \033[0;33mPrimary IP:\033[0m   not assigned\n"
        fi
        if [ -n "${OTHER_IPS}" ]; then
            local first=1
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$first" = "1" ]; then
                    printf "    \033[0;33mOther IPs:\033[0m    %s\n" "$line"
                    first=0
                else
                    printf "                  %s\n" "$line"
                fi
            done <<EOF
${OTHER_IPS}
EOF
        fi
        printf "    \033[0;33mActive Slot:\033[0m  %s (%s)\n" "${RAUC_SLOT}" "${RAUC_STATUS}"
        printf "    \033[0;33mOTA State:\033[0m    %s\n" "${RAUC_OP}"
        if [ "${RAUC_LAST_ERROR}" != "none" ] && [ -n "${RAUC_LAST_ERROR}" ]; then
            printf "    \033[0;33mOTA LastError:\033[0m %s\n" "${RAUC_LAST_ERROR}"
        fi
        printf "    \033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\n"
        printf "    \033[0;36m📚 Documentation:\033[0m https://github.com/umair-as/rpi5-iot-gateway\n"
        printf "    \033[0;36m💬 Support:\033[0m Umair A.S. \n"
        printf "\033[0m\n"
    } > "${MOTD_FILE}"
}

get_system_info

case "${1:-all}" in
    issue)
        generate_issue
        ;;
    issue.net)
        generate_issue_net
        ;;
    motd)
        generate_motd
        ;;
    all|*)
        generate_issue
        generate_issue_net
        generate_motd
        ;;
esac
