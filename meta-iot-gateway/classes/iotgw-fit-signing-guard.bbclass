# ── FIT signing guard (signed-or-fail policy) ────────────────────────────────
# Hard-fails the build when FIT signing is off, or when no operator signing key
# is usable (which would otherwise yield an unsigned FIT that the hardened
# U-Boot, CONFIG_FIT_SIGNATURE=y, cannot boot anyway). "Signed" = ANY ONE of
# {file-key, YubiKey, SoftHSM} certificate present. The file key counts
# unconditionally — it is operator-generated (gitignored, never shipped) and is
# the normal build-time / Stage-1 signer. There is NO unsigned escape hatch.
#
# Modeled on iotgw-uboot-prod-key-guard: a task on the u-boot recipe, before
# do_configure, so it fails the BUILD early (before the kernel/rootfs compile)
# WITHOUT blocking `bitbake -e` / `make parse` / `make layers` for keyless
# metadata inspection. Inherited via u-boot_%.bbappend.

python do_iotgw_fit_signing_guard() {
    import os

    signing = (d.getVar('IOTGW_FIT_SIGNING') or '0').strip()
    if signing != '1':
        bb.fatal(
            '\n'
            'FIT signed boot is the ONLY supported flow, but IOTGW_FIT_SIGNING '
            'is "%s" (expected "1").\n'
            'This distro refuses to produce an unsigned FIT image.\n'
            'Leave IOTGW_FIT_SIGNING at its default and configure a signing key '
            'in kas/local.yml (see kas/local.yml.example, fit_signing block).'
            % signing
        )

    def _cert_present(keydir_var, keyname_var):
        keydir = (d.getVar(keydir_var) or '').strip()
        keyname = (d.getVar(keyname_var) or '').strip()
        if not keydir or not keyname:
            return False
        return os.path.isfile(os.path.join(keydir, keyname + '.crt'))

    # File key: always a valid signer (no trust-gate precondition — it is the
    # build-time signer and IOTGW_FIT_TRUST_FILE_KEY defaults on). YubiKey /
    # SoftHSM only count when their trust gate is explicitly enabled, so a stale
    # cert left in a keydir with the gate off does not falsely satisfy the check.
    file_ok = _cert_present('UBOOT_SIGN_KEYDIR', 'UBOOT_SIGN_KEYNAME')
    yk_ok = ((d.getVar('IOTGW_FIT_TRUST_YK_KEY') or '0').strip() == '1'
             and _cert_present('IOTGW_FIT_YK_KEYDIR', 'IOTGW_FIT_YK_KEYNAME'))
    softhsm_ok = ((d.getVar('IOTGW_FIT_TRUST_SOFTHSM_KEY') or '0').strip() == '1'
                  and _cert_present('IOTGW_FIT_SOFTHSM_KEYDIR', 'IOTGW_FIT_SOFTHSM_KEYNAME'))

    if not (file_ok or yk_ok or softhsm_ok):
        bb.fatal(
            '\n'
            'FIT signing is required but NO usable operator signing key was found.\n'
            'At least one signing certificate must exist:\n'
            '  - file key : %s/%s.crt\n'
            '  - YubiKey  : %s/%s.crt   (with IOTGW_FIT_TRUST_YK_KEY = "1")\n'
            '  - SoftHSM  : %s/%s.crt   (with IOTGW_FIT_TRUST_SOFTHSM_KEY = "1")\n'
            '\n'
            'These are operator-generated key material (gitignored, never shipped).\n'
            'Create kas/local.yml from kas/local.yml.example and set the file-key\n'
            'block (UBOOT_SIGN_KEYDIR / UBOOT_SIGN_KEYNAME) pointing at your key,\n'
            'or generate one per docs/FIT_BOOT_SIGNING.md ("Generate a dev signing key").'
            % (
                d.getVar('UBOOT_SIGN_KEYDIR') or '<UBOOT_SIGN_KEYDIR unset>',
                d.getVar('UBOOT_SIGN_KEYNAME') or '<UBOOT_SIGN_KEYNAME unset>',
                d.getVar('IOTGW_FIT_YK_KEYDIR') or '<IOTGW_FIT_YK_KEYDIR unset>',
                d.getVar('IOTGW_FIT_YK_KEYNAME') or '<IOTGW_FIT_YK_KEYNAME unset>',
                d.getVar('IOTGW_FIT_SOFTHSM_KEYDIR') or '<IOTGW_FIT_SOFTHSM_KEYDIR unset>',
                d.getVar('IOTGW_FIT_SOFTHSM_KEYNAME') or '<IOTGW_FIT_SOFTHSM_KEYNAME unset>',
            )
        )

    bb.debug(1, 'iotgw-fit-signing-guard: usable signing key present, passes.')
}

addtask iotgw_fit_signing_guard before do_configure after do_patch
