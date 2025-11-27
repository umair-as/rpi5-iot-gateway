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
    IP_ADDR=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1 || echo "N/A")
    RAUC_SLOT=$(rauc status 2>/dev/null | grep "Booted from:" | awk '{print $3}' || echo "unknown")
}

# Generate /etc/issue (login screen) - simple version with legal warning
generate_issue() {
    get_system_info

    # Pre-login message with legal warning banner and system info
    {
        printf "\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\033[1;33m                              ⚠ AUTHORIZED ACCESS ONLY ⚠\033[0m\n"
        printf "\033[0;37mThis system is for authorized use only. All activity is monitored and logged.\n"
        printf "Unauthorized access is not permitted.\033[0m\n"
        printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
        printf "\n"
        printf "\033[1;36m%s\033[0m \033[0;37m%s\033[0m\n" "${DISTRO_NAME}" "${DISTRO_VERSION}"
        printf "\033[0;33mMachine:\033[0m %s | \033[0;33mTTY:\033[0m \\l\n" "${MACHINE}"
        printf "\n"
    } > /etc/issue
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
        printf "    \033[0;36m💬 Support:\033[0m Umair A.S. and the team\n"
        printf "\033[0m\n"
    } > /etc/motd
}

# Main execution
case "${1:-all}" in
    issue)
        generate_issue
        ;;
    motd)
        generate_motd
        ;;
    all|*)
        generate_issue
        generate_motd
        ;;
esac
