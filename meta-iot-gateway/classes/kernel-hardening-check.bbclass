# BBClass to check kernel hardening configuration
# Adds a 'do_kernel_hardening_check' task to kernel recipes

DEPENDS:append = " kernel-hardening-checker-native"

# Task to run kernel hardening checker
do_kernel_hardening_check() {
    if [ ! -f "${B}/.config" ]; then
        bbwarn "Kernel .config not found at ${B}/.config, skipping hardening check"
        return 0
    fi

    bbnote "Running kernel hardening checker on ${B}/.config"

    # Run checker with output to log file
    REPORT="${WORKDIR}/kernel-hardening-report.txt"

    kernel-hardening-checker -c "${B}/.config" -m verbose > "${REPORT}" 2>&1 || {
        bbwarn "Kernel hardening checker found issues, see ${REPORT}"
        cat "${REPORT}"
        return 0
    }

    bbnote "Kernel hardening check passed, report: ${REPORT}"
    cat "${REPORT}"
}

# Run after kernel configuration but before compilation
addtask kernel_hardening_check after do_kernel_configme before do_compile
do_kernel_hardening_check[nostamp] = "1"
