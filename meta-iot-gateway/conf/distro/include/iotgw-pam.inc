# PAM for every image tier.
#
# Logins go through PAM so that pam_selinux sets the session's SELinux
# context and relabels the terminal, and pam_unix checks passwords through
# unix_chkpwd instead of the login program reading /etc/shadow itself. With
# the feature on, OE-Core builds shadow (login, su), openssh (UsePAM), sudo,
# util-linux, systemd and kbd against libpam; meta-selinux builds libpam with
# pam_selinux and policycoreutils' newrole with PAM. The layer's own stacks
# for login and sshd live in shadow_%.bbappend and openssh_%.bbappend.
#
# Password aging becomes enforced at login (pam_unix account): accounts
# created under the hardened login.defs (PASS_MAX_DAYS 90) with the
# reproducible-build change date are born expired. root and devel are exempt
# (iotgw_rootfs_root_password_aging, useradd -K PASS_MAX_DAYS=99999); service
# accounts do not log in, and a unit that opens a PAM session for one
# (PAMName=) needs the same treatment weston got.
DISTRO_FEATURES:append = " pam"

