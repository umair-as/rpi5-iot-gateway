# ── Production FIT signing key guard ─────────────────────────────────────────
# Prevents iot-gw-image-prod from being built with a development signing key.

python do_iotgw_uboot_key_guard() {
    # No-op when FIT signing is disabled entirely
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

    # Enforce: prod image must not reference a dev-named key
    keyname = d.getVar('UBOOT_SIGN_KEYNAME') or ''
    if 'dev' in keyname.lower():
        bb.fatal(
            '\n'
            'iot-gw-image-prod cannot be built with a development FIT signing key.\n'
            'UBOOT_SIGN_KEYNAME is "%s" which matches the dev key pattern.\n'
            'Production builds require a key named "iotgw-fit-prod" or similar,\n'
            'generated and stored per docs/KEY_CEREMONY.md.\n'
            'To proceed: set UBOOT_SIGN_KEYNAME to a non-dev key in kas/local.yml '
            'under the fit_signing_prod block.' % keyname
        )

    bb.debug(1, 'iotgw-uboot-prod-key-guard: key "%s" passes prod check.' % keyname)
}

addtask iotgw_uboot_key_guard before do_configure after do_patch
