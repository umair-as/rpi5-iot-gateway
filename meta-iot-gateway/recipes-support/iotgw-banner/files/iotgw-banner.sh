#!/bin/bash
# IoT Gateway Dynamic Banner Generator
# Generates modern, colorful banners with system information

# System info (substituted at build time)
DISTRO_NAME="@DISTRO_NAME@"
DISTRO_VERSION="@DISTRO_VERSION@"
MACHINE="@MACHINE@"

# Dynamic system info
get_system_info() {
    KERNEL=$(uname -r 2>/dev/null || echo "unknown")
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")

    # Resolve primary IP address with robust fallbacks
    IP_ADDR=""
    if command -v hostname >/dev/null 2>&1; then
        IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    if [ -z "$IP_ADDR" ] && command -v ip >/dev/null 2>&1; then
        IP_ADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'match($0,/src ([0-9.]+)/,m){print m[1]}') || true
    fi
    if [ -z "$IP_ADDR" ] && command -v ip >/dev/null 2>&1; then
        IP_ADDR=$(ip -4 addr show scope global up 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1) || true
    fi
    [ -n "$IP_ADDR" ] || IP_ADDR="N/A"

    RAUC_SLOT=$(rauc status 2>/dev/null | grep "Booted from:" | awk '{print $3}' || echo "unknown")
}

# Generate /etc/issue (login screen) - simple version with legal warning
generate_issue() {
    get_system_info

    # Pre-login message with legal warning banner and system info
    {
        printf "\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\033[1;33m                              ℹ Authorized users only\033[0m\n"
        printf "\033[0;37mThis device is intended for authorized use. Connections may be logged to\n"
        printf "help ensure reliability and security. If you weren't expecting access,\n"
        printf "please disconnect and contact the administrator.\033[0m\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\n"
        printf "\033[1;36m%s\033[0m \033[0;37m%s\033[0m\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "\033[0;33mMachine:\033[0m %s | \033[0;33mTTY:\033[0m \\l\n" "${MACHINE}"
        printf "\n"
    } > /etc/issue
}

# Generate /etc/issue.net (SSH/network pre-login banner)
generate_issue_net() {
    # Network login banner with legal warning (no ANSI colors for compatibility)
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
        printf "%s %s\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "Machine: %s\n" "${MACHINE}"
        printf "\n"
    } > /etc/issue.net
}

# Generate /etc/motd (post-login message)
generate_motd() {
    get_system_info

    # Use printf for consistent ANSI escape handling
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

        # System information - clean format without borders
        printf "    \033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "    \033[0;33mPlatform:\033[0m     %s\n" "${MACHINE}"
        printf "    \033[0;33mKernel:\033[0m       %s\n" "${KERNEL}"
        printf "    \033[0;33mUptime:\033[0m       %s\n" "${UPTIME}"
        printf "    \033[0;33mIP Address:\033[0m   %s\n" "${IP_ADDR}"
        printf "    \033[0;33mActive Slot:\033[0m  %s\n" "${RAUC_SLOT}"
        printf "    \033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\n"

        # Footer
        printf "    \033[0;36m📚 Documentation:\033[0m https://github.com/umair-uas/rpi5-kas-project\n"
        printf "    \033[0;36m💬 Support:\033[0m Umair A.S. \n"
        printf "\033[0m\n"
    } > /etc/motd
}

# Main execution
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
