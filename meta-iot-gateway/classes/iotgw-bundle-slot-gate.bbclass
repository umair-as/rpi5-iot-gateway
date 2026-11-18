# ── Bundle slot-FIT gate (assembly check on the staged files) ────────────────
# The last check before a RAUC bundle is packed, run on the files meta-rauc's
# do_configure has just copied into ${BUNDLE_DIR}, i.e. exactly what ships:
#   - the trust anchor is the DTB inside the staged bootfiles archive (what OTA
#     installs), and holds exactly the build's enabled trust roots;
#   - both staged slot FITs verify against it, signed over kernel and fdt;
#   - their command lines carry the slot identity and the dm-verity table the
#     image recipe generates, and the staged rootfs verifies against that table.
# Under the release-trust profile the image's slot FITs are file-signed
# intermediates, so this refuses to assemble until the operator has re-signed
# them (sign_fit.py sign-slot-fits). Signing is never run from here.
#
# Checker: meta-iot-gateway/scripts/slot_fits.py (uses iotgw-fit-gate.py).

inherit iotgw-fit-gate

IOTGW_SLOT_FITS = "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/slot_fits.py')}"
IOTGW_BUNDLE_SLOT_IMAGE = "${RAUC_SLOT_rootfs}${IMAGE_MACHINE_SUFFIX}${IMAGE_NAME_SUFFIX}"
# Must match iotgw-verity-image.bbclass. A mismatch fails closed: the table the
# FIT carries would not equal the one checked here.
IOTGW_VERITY_SLOT_A_DEV ?= "/dev/mmcblk0p3"
IOTGW_VERITY_SLOT_B_DEV ?= "/dev/mmcblk0p4"

DEPENDS += "u-boot-tools-native dtc-native cryptsetup-native"
do_configure[postfuncs] += "iotgw_bundle_slot_gate"
do_configure[file-checksums] += "${IOTGW_SLOT_FITS}:True ${IOTGW_FIT_GATE}:True"

# Track the deploy-side inputs by content, so a re-signed pair (same names, new
# bytes) re-runs assembly instead of reusing the file-signed result. This only
# invalidates; the gate above is what verifies.
python __anonymous() {
    image = d.getVar('IOTGW_BUNDLE_SLOT_IMAGE')
    deploy = d.getVar('DEPLOY_DIR_IMAGE')
    names = ['%s.fitImage-a' % image, '%s.fitImage-b' % image, '%s.ext4.verity-params' % image]
    if d.getVar('IOTGW_RAUC_UPDATE_BOOTFILES') == '1':
        names.append(d.getVar('IOTGW_RAUC_BOOTFILES_SOURCE_FILE'))
    d.appendVarFlag('do_configure', 'file-checksums',
                    ' ' + ' '.join('%s/%s:False' % (deploy, n) for n in names))
}

python iotgw_bundle_slot_gate() {
    import os
    import subprocess
    if d.getVar('IOTGW_RAUC_UPDATE_BOOTFILES') != '1':
        bb.fatal("bundle slot gate: the bundle ships no bootfiles archive, so there is no "
                 "shipped trust anchor to check the slot FITs against")
    bundle = d.getVar('BUNDLE_DIR')
    image = d.getVar('IOTGW_BUNDLE_SLOT_IMAGE')
    keys = iotgw_fit_gate_trusted(d)
    sign_alg = d.getVar('FIT_SIGN_ALG')
    cmd = ['python3', d.getVar('IOTGW_SLOT_FITS'), 'check',
           '--image', image, '--deploy-dir', d.getVar('DEPLOY_DIR_IMAGE'),
           '--archive', os.path.join(bundle, d.getVar('IOTGW_RAUC_BOOTFILES_BUNDLE_FILE')),
           '--anchor-member', d.getVar('IOTGW_FIT_ANCHOR_DTB'),
           '--keys'] + keys + [
           '--algo', '%s,%s' % (d.getVar('FIT_HASH_ALG'), sign_alg),
           '--bits', ''.join(c for c in sign_alg if c.isdigit()),
           '--slot-a-device', d.getVar('IOTGW_VERITY_SLOT_A_DEV'),
           '--slot-b-device', d.getVar('IOTGW_VERITY_SLOT_B_DEV'),
           '--fit-a', os.path.join(bundle, '%s.fitImage-a' % image),
           '--fit-b', os.path.join(bundle, '%s.fitImage-b' % image),
           '--rootfs', os.path.join(bundle, '%s.ext4.verity' % image),
           '--checker', os.path.join(d.getVar('STAGING_BINDIR_NATIVE'), 'fit_check_sign'),
           '--gate', d.getVar('IOTGW_FIT_GATE')]
    run = subprocess.run(cmd, capture_output=True, text=True)
    if run.returncode != 0:
        hint = ""
        if d.getVar('IOTGW_FIT_TRUST_FILE_KEY') != '1':
            hint = ("\nRelease trust: the slot FITs must be re-signed by the operator before "
                    "bundling (make sign-slot-fits-yk, see docs/FIT_BOOT_SIGNING.md), then "
                    "re-run the bundle target.")
        bb.fatal("bundle slot gate refused %s:\n%s%s" % (image, run.stderr.strip(), hint))
    bb.note("bundle slot gate OK: %s (anchor keys: %s)" % (image, ' '.join(keys)))
}
