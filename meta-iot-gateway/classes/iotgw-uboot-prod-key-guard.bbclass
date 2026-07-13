# ── Production FIT trust-profile guard ───────────────────────────────────────
# Ensures iot-gw-image-prod is built with the release FIT trust profile: the
# deployed U-Boot control FDT must trust ONLY the YubiKey-resident pubkey.
#
# This guard deliberately does NOT inspect UBOOT_SIGN_KEYNAME. Under the
# detached-signing model (PRs #70-#74), the build-time file key signs only a
# Stage-1 placeholder FIT that is re-signed against the YubiKey post-build; it
# is never a trust root in a release DTB (IOTGW_FIT_TRUST_FILE_KEY=0). The
# build-time key name is therefore irrelevant to release security — what
# matters is the trust-gate set baked into the control FDT.

python do_iotgw_uboot_key_guard() {
    # No-op when FIT signing is disabled entirely.
    fit_signing = d.getVar('IOTGW_FIT_SIGNING') or '0'
    if fit_signing != '1':
        bb.debug(1, 'iotgw-uboot-prod-key-guard: IOTGW_FIT_SIGNING != 1, skipping.')
        return

    # In u-boot recipe context IMAGE_BASENAME is usually unset, so also treat
    # prod-intent feature tokens as a production build signal.
    image_basename = d.getVar('IMAGE_BASENAME') or ''
    features = (d.getVar('IOTGW_UBOOT_FEATURES') or '').split()
    prod_intent = (
        image_basename == 'iot-gw-image-prod'
        or 'appliance_lockdown' in features
    )
    if not prod_intent:
        pn = d.getVar('PN') or ''
        bb.debug(1, 'iotgw-uboot-prod-key-guard: not prod-intent (%s, %s), skipping.' % (pn, ' '.join(features)))
        return

    # Enforce the release FIT trust profile: the production control FDT must
    # trust ONLY the YubiKey root — the dev file key and the dev SoftHSM key
    # must both be off so they are not injected as /signature/key-* nodes.
    trust_yk      = d.getVar('IOTGW_FIT_TRUST_YK_KEY') or '0'
    trust_file    = d.getVar('IOTGW_FIT_TRUST_FILE_KEY') or '0'
    trust_softhsm = d.getVar('IOTGW_FIT_TRUST_SOFTHSM_KEY') or '0'

    bad = []
    if trust_yk != '1':
        bad.append('IOTGW_FIT_TRUST_YK_KEY must be "1" (the production trust root) but is "%s"' % trust_yk)
    if trust_file == '1':
        bad.append('IOTGW_FIT_TRUST_FILE_KEY must be "0" but is "1" — the dev file key would be a release trust root')
    if trust_softhsm == '1':
        bad.append('IOTGW_FIT_TRUST_SOFTHSM_KEY must be "0" but is "1" — the dev SoftHSM key would be a release trust root')

    if bad:
        bb.fatal(
            '\n'
            'iot-gw-image-prod must be built with the release FIT trust profile —\n'
            'the deployed U-Boot control FDT must trust ONLY the YubiKey root:\n\n'
            '  - ' + '\n  - '.join(bad) + '\n\n'
            'Fix: build via a prod target (make prod / bundle-prod-full /\n'
            'bundle-prod-full-fit) so the Makefile composes kas/fit-release-trust.yml,\n'
            'and ensure kas/local.yml enables the YubiKey trust root\n'
            '(IOTGW_FIT_TRUST_YK_KEY = "1" plus IOTGW_FIT_YK_KEYDIR / KEYNAME).\n'
            'See docs/FIT_BOOT_SIGNING.md, section "Release vs dev KAS trust profiles".'
        )

    bb.debug(1, 'iotgw-uboot-prod-key-guard: release trust profile active (YubiKey-only), passes.')
}

addtask iotgw_uboot_key_guard before do_configure after do_patch
