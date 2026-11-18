# ── FIT trust gate (build-time anchor + shipped-FIT verification) ────────────
# iotgw-fit-signing-guard only checks that a signing key is configured. This
# class checks the result: the board DTB that becomes U-Boot's control FDT
# carries exactly the enabled trust roots, each required="conf" with the
# expected algorithm, and both per-slot dm-verity FITs the image ships verify
# against that DTB with fit_check_sign. A failure stops the image before a WIC
# or bundle that would not boot, or would boot something it should not, is
# produced.
#
# Checker: meta-iot-gateway/scripts/iotgw-fit-gate.py.
# Negative self-test: scripts/fit-signing/fit-gate-selftest.sh.
#
# The slot FITs are signed in-band with the file key. When that key is a trust
# root (dev and dual trust) they must verify against the shipped anchor. Under
# the release-trust profile they cannot: they are intermediates the operator
# re-signs with the HSM key. Then they are checked here against an anchor
# holding only the build key (signature present, kernel+fdt covered, intact),
# and the release anchor is applied where it can pass: by
# iotgw-bundle-slot-gate.bbclass on the files the bundle actually ships, after
# signing.

IOTGW_FIT_GATE = "${@bb.utils.which(d.getVar('BBPATH'), 'scripts/iotgw-fit-gate.py')}"
IOTGW_FIT_ANCHOR_DTB ?= "bcm2712-rpi-5-b.dtb"

# The slot FITs are made, and checked, before do_image_wic; the anchor is
# checked again right before the WIC copies it into the boot partition.
do_image_verity_fit[postfuncs] += "iotgw_fit_gate_anchor iotgw_fit_gate_slot_fits"
do_image_verity_fit[file-checksums] += "${IOTGW_FIT_GATE}:True"
do_image_wic[depends] += "u-boot-tools-native:do_populate_sysroot dtc-native:do_populate_sysroot"
do_image_wic[prefuncs] += "iotgw_fit_gate_anchor"
do_image_wic[file-checksums] += "${IOTGW_FIT_GATE}:True"

def iotgw_fit_gate_trusted(d):
    keys = []
    if d.getVar('IOTGW_FIT_TRUST_FILE_KEY') == '1':
        keys.append(d.getVar('UBOOT_SIGN_KEYNAME'))
    if d.getVar('IOTGW_FIT_TRUST_YK_KEY') == '1':
        keys.append(d.getVar('IOTGW_FIT_YK_KEYNAME'))
    if d.getVar('IOTGW_FIT_TRUST_SOFTHSM_KEY') == '1':
        keys.append(d.getVar('IOTGW_FIT_SOFTHSM_KEYNAME'))
    return keys

def iotgw_fit_gate_run(d, args):
    import subprocess
    gate = d.getVar('IOTGW_FIT_GATE')
    if not gate:
        bb.fatal("FIT trust gate script scripts/iotgw-fit-gate.py not found in BBPATH")
    run = subprocess.run(['python3', gate] + args, capture_output=True, text=True)
    if run.returncode != 0:
        bb.fatal("FIT trust gate failed:\n%s" % run.stderr.strip())

def iotgw_fit_gate_anchor_path(d):
    import os
    return os.path.join(d.getVar('DEPLOY_DIR_IMAGE'), d.getVar('IOTGW_FIT_ANCHOR_DTB'))

python iotgw_fit_gate_anchor() {
    if d.getVar('UBOOT_SIGN_ENABLE') != '1':
        bb.fatal("FIT trust gate: UBOOT_SIGN_ENABLE is not 1; signed FIT boot is mandatory.")
    keys = iotgw_fit_gate_trusted(d)
    if not keys:
        bb.fatal("FIT trust gate: no IOTGW_FIT_TRUST_* root is enabled.")
    # Key size comes from the algorithm name (rsa2048): fdt_add_pubkey takes the
    # size from each certificate, and FIT_SIGN_NUMBITS only sizes generated keys.
    sign_alg = d.getVar('FIT_SIGN_ALG')
    bits = ''.join(c for c in sign_alg if c.isdigit())
    if not bits:
        bb.fatal("FIT trust gate: cannot derive the key size from FIT_SIGN_ALG=%r" % sign_alg)
    dtb = iotgw_fit_gate_anchor_path(d)
    iotgw_fit_gate_run(d, ['anchor', '--dtb', dtb, '--keys'] + keys +
                       ['--algo', '%s,%s' % (d.getVar('FIT_HASH_ALG'), sign_alg),
                        '--bits', bits])
    bb.note("FIT anchor OK: %s (%s)" % (dtb, ' '.join(keys)))
}

python iotgw_fit_gate_slot_fits() {
    import os
    import subprocess
    deploy = d.getVar('IMGDEPLOYDIR')
    if d.getVar('IOTGW_FIT_TRUST_FILE_KEY') == '1':
        dtb = iotgw_fit_gate_anchor_path(d)
        what = "the shipped anchor"
    else:
        # Release trust: an anchor trusting only the build key, never shipped.
        dtb = os.path.join(d.getVar('T'), 'fit-intermediate-anchor.dtb')
        dts = dtb[:-len('.dtb')] + '.dts'
        with open(dts, 'w') as f:
            f.write('/dts-v1/;\n/ { };\n')
        cmds = [['dtc', '-I', 'dts', '-O', 'dtb', '-o', dtb, dts],
                ['fdt_add_pubkey', '-a', '%s,%s' % (d.getVar('FIT_HASH_ALG'), d.getVar('FIT_SIGN_ALG')),
                 '-k', d.getVar('UBOOT_SIGN_KEYDIR'), '-n', d.getVar('UBOOT_SIGN_KEYNAME'),
                 '-r', 'conf', dtb]]
        for cmd in cmds:
            run = subprocess.run(cmd, capture_output=True, text=True)
            if run.returncode != 0:
                bb.fatal("FIT trust gate: cannot build the intermediate anchor (%s): %s"
                         % (cmd[0], run.stderr.strip()))
        what = "the build key only (release trust: intermediate, operator re-signs before bundling)"
    for name in (d.getVar('IOTGW_VERITY_FIT_A'), d.getVar('IOTGW_VERITY_FIT_B')):
        iotgw_fit_gate_run(d, ['fit', '--dtb', dtb, '--fit', os.path.join(deploy, name)])
        bb.note("slot FIT verifies against %s: %s" % (what, name))
}
do_image_verity_fit[depends] += "u-boot-tools-native:do_populate_sysroot dtc-native:do_populate_sysroot"
