# Set restrictive umask (AUTH-9328)
umask 027

# Disable core dumps for interactive shells as a fallback when PAM limits
# are not applied (e.g., non-login shells). Kernel/systemd services are
# covered by limits/systemd configs separately.
ulimit -S -c 0 2>/dev/null || true
