## IoT Gateway distro hardening include
# Pull in OE-Core's tested security flags set (PIE, FORTIFY, relro/now, stack protector).
# In Poky this is included by default; with oe-core-only distros we include it explicitly.

require conf/distro/include/security_flags.inc

# Optional: enable extra hardening if supported by your toolchain (uncomment to opt-in)
# SECURITY_STACK_PROTECTOR = "-fstack-protector-strong -fstack-clash-protection"

