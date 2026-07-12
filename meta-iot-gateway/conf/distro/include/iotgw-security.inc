## IoT Gateway distro hardening include
# OE-Core's tested security flags set (PIE, FORTIFY, relro/now, stack
# protector) comes from defaultsetup.conf's security_flags.inc. Its variables
# are weak (?=) assignments, so distro-level overrides set here still win.

# Optional: enable extra hardening if supported by your toolchain (uncomment to opt-in)
# SECURITY_STACK_PROTECTOR = "-fstack-protector-strong -fstack-clash-protection"

