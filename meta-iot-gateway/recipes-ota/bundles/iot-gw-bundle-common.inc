## Common RAUC bundle settings for IoT Gateway bundles

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit bundle iotgw-rauc-adaptive-guard

# Bundle identity (matches device system.conf via rauc-conf)
RAUC_BUNDLE_COMPATIBLE ?= "iot-gateway-${MACHINE}"

# Control whether to update /boot (kernel/DTBs) via bundle hook. FIT is the only
# boot flow, so the bootfiles archive/hook default to the FIT-aware variants
# (there is no non-FIT bundle).
IOTGW_RAUC_UPDATE_BOOTFILES ?= "0"
IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE ?= "rpi-bootfiles-archive-fit"
IOTGW_RAUC_BOOTFILES_HOOK_FILE ?= "bundle-hooks-fit.sh"
IOTGW_RAUC_BOOTFILES_SOURCE_FILE ?= "bootfiles-fit.tar.gz"
IOTGW_RAUC_BOOTFILES_BUNDLE_FILE ?= "bootfiles-fit.tar.gz"

# Slots included in the bundle
RAUC_BUNDLE_SLOTS = "rootfs"
# Keep adaptive updates opt-in by default. When enabled, a build-time guard
# validates IoT GW RAUC rootA/rootB geometry is 4KiB aligned.
IOTGW_RAUC_ADAPTIVE ?= "0"

# Use the selected image for the rootfs slot (set BUNDLE_IMAGE in variants)
RAUC_SLOT_rootfs = "${BUNDLE_IMAGE}"
RAUC_SLOT_rootfs[fstype] = "ext4"
# Run pre/post hooks for update-scoped reconciliation and bootfile handling.
RAUC_SLOT_rootfs[hooks] = "pre-install;post-install"
# Optional RAUC adaptive updates (block-hash-index) to reduce rewritten data
# when installing near-identical rootfs images.
RAUC_SLOT_rootfs[adaptive] = "${@bb.utils.contains('IOTGW_RAUC_ADAPTIVE','1','block-hash-index','',d)}"

# Bundle format. Encrypted `crypt` is the DEFAULT posture; `verity` is reached
# only by the explicit opt-out. No default is declared here on purpose — the
# single canonical decision and its crypt/verity mapping live in the distro
# include, and rauc-conf-iotgw reads the same value for the target half.
RAUC_BUNDLE_FORMAT = "${IOTGW_RAUC_BUNDLE_FORMAT_EFFECTIVE}"

# Include bootfiles archive and a hook to update /boot (conditional)
RAUC_BUNDLE_EXTRA_DEPENDS += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' ${IOTGW_RAUC_BOOTFILES_ARCHIVE_RECIPE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES += "${@bb.utils.contains('IOTGW_RAUC_UPDATE_BOOTFILES','1',' ${IOTGW_RAUC_BOOTFILES_BUNDLE_FILE}','',d)}"
RAUC_BUNDLE_EXTRA_FILES += " overlay-reconcile.py"
RAUC_BUNDLE_HOOKS[file] = "${IOTGW_RAUC_BOOTFILES_HOOK_FILE}"

# meta-rauc bundle.bbclass uses a python do_configure() task and expects plain
# filenames in RAUC_BUNDLE_EXTRA_FILES. For variant flows, normalize deploy
# artifact name into the bundle filename in WORKDIR.
python do_configure:prepend() {
    import os
    import shutil

    if d.getVar("IOTGW_RAUC_UPDATE_BOOTFILES") == "1":
        src_name = d.getVar("IOTGW_RAUC_BOOTFILES_SOURCE_FILE")
        dst_name = d.getVar("IOTGW_RAUC_BOOTFILES_BUNDLE_FILE")

        if src_name != dst_name:
            src = os.path.join(d.getVar("DEPLOY_DIR_IMAGE"), src_name)
            dst = os.path.join(d.getVar("WORKDIR"), dst_name)

            if not os.path.isfile(src):
                bb.fatal("Bootfiles source archive not found: %s" % src)

            shutil.copyfile(src, dst)
}

# Make RAUC cert and hooks available via FILESEXTRAPATHS
FILESEXTRAPATHS:prepend := "${THISDIR}/../rauc/files:"
SRC_URI:append = " \
    file://${IOTGW_RAUC_BOOTFILES_HOOK_FILE};mode=0755 \
    file://overlay-reconcile.py;mode=0755 \
"

# Key and cert paths must be provided via local.conf or kas/local.yml
# Example in kas/local.yml.example:
#   RAUC_KEY_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-key.pem"
#   RAUC_CERT_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-cert.pem"

# Output name
BUNDLE_BASENAME = "${BUNDLE_IMAGE}-bundle"
BUNDLE_NAME = "${BUNDLE_BASENAME}"

# Encrypt the bundle IN PLACE rather than using upstream's
# RAUC_ENCRYPT_CRYPT_BUNDLE.
#
# meta-rauc's bundle.bbclass supports encryption via RAUC_ENCRYPT_CRYPT_BUNDLE
# + RAUC_RECIPIENTS_CERT_FILE, but its do_deploy() then installs TWO artifacts:
# the encrypted one under ENCRYPTED_BUNDLE_NAME, and the un-enveloped
# `bundle.raucb` under the normal BUNDLE_NAME. For a `crypt` bundle that second
# artifact is not merely redundant, it is a disclosure: before `rauc encrypt`
# runs, the payload key still sits in the plain manifest, so anyone holding
# that file can decrypt the rootfs image. It would also carry the exact
# filename every operator script, the release manifest and the OTA server
# already expect, so the unencrypted copy is the one most likely to be shipped.
#
# Overwriting bundle.raucb keeps a single artifact, under the established name,
# in the only state we are willing to publish. RAUC_ENCRYPT_CRYPT_BUNDLE stays
# at its upstream default of "0" and is asserted below, so the two mechanisms
# can never both run.
do_bundle:append() {
    keyring=""

    if [ "${RAUC_ENCRYPT_CRYPT_BUNDLE}" = "1" ]; then
        bbfatal "RAUC_ENCRYPT_CRYPT_BUNDLE=1 conflicts with this layer's in-place encryption in do_bundle:append(). Upstream's path deploys a SECOND, unencrypted bundle under the normal BUNDLE_NAME. Leave it at 0."
    fi

    if [ "${IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION}" != "1" ]; then
        # Verity opt-out. Assert the format actually followed the toggle, so a
        # mis-set RAUC_BUNDLE_FORMAT cannot leave a crypt bundle unencrypted.
        if [ "${RAUC_BUNDLE_FORMAT}" = "crypt" ]; then
            rm -f ${B}/bundle.raucb
            bbfatal "RAUC_BUNDLE_FORMAT is 'crypt' but encryption is disabled. That combination produces a crypt bundle whose payload key is readable in the plain manifest. Refusing to keep it."
        fi
        exit 0
    fi

    if [ "${RAUC_BUNDLE_FORMAT}" != "crypt" ]; then
        rm -f ${B}/bundle.raucb
        bbfatal "Encrypted bundle posture is active but RAUC_BUNDLE_FORMAT is '${RAUC_BUNDLE_FORMAT}'. Only 'crypt' can carry an enveloped CMS."
    fi

    # These four checks are the gate. Remove the intermediate before failing —
    # at this point ${B}/bundle.raucb is a crypt bundle that has NOT been
    # enveloped, i.e. its payload key is still readable. RAUC and OpenSSL reject
    # malformed or unusable certificate material themselves when `rauc encrypt`
    # runs below, so nothing here re-implements certificate policy.
    if [ -z "${IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        rm -f ${B}/bundle.raucb
        bbfatal "'IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS' not set while encrypted bundle mode is enabled"
    fi
    if [ ! -f "${IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" ]; then
        rm -f ${B}/bundle.raucb
        bbfatal "Encrypted bundle recipients file not found: ${IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}"
    fi
    keyring="${RAUC_KEYRING_FILE}"
    if [ -z "${keyring}" ] || [ ! -f "${keyring}" ]; then
        if [ -n "${RAUC_DEVICE_KEYRING}" ] && [ -f "${RAUC_DEVICE_KEYRING}" ]; then
            keyring="${RAUC_DEVICE_KEYRING}"
        elif [ -n "${RAUC_CERT_FILE}" ] && [ -f "${RAUC_CERT_FILE}" ]; then
            keyring="${RAUC_CERT_FILE}"
        fi
    fi
    if [ -z "${keyring}" ] || [ ! -f "${keyring}" ]; then
        rm -f ${B}/bundle.raucb
        bbfatal "No usable RAUC keyring file found for encrypted bundle workflow (tried RAUC_KEYRING_FILE='${RAUC_KEYRING_FILE}', RAUC_DEVICE_KEYRING='${RAUC_DEVICE_KEYRING}', RAUC_CERT_FILE='${RAUC_CERT_FILE}')"
    fi

    if ! ${STAGING_BINDIR_NATIVE}/rauc encrypt \
        --to="${IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}" \
        --keyring="${keyring}" \
        ${B}/bundle.raucb \
        ${B}/bundle-encrypted.raucb; then
        rm -f ${B}/bundle.raucb ${B}/bundle-encrypted.raucb
        bbfatal "rauc encrypt failed for recipients '${IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS}'. Both the unencrypted intermediate and the partial output were removed."
    fi

    mv -f ${B}/bundle-encrypted.raucb ${B}/bundle.raucb
}

do_bundle[vardeps] += "IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS RAUC_BUNDLE_FORMAT RAUC_ENCRYPT_CRYPT_BUNDLE RAUC_KEYRING_FILE RAUC_DEVICE_KEYRING RAUC_CERT_FILE"

# ...and the recipient certificate's CONTENT, not just the path to it.
#
# [vardeps] above hashes the VARIABLE, which is a path string. Rotating the
# certificate in place -- routine renewal, or a key-compromise response --
# leaves do_bundle's signature unchanged, so bitbake reuses the bundle
# encrypted to the OLD recipient from the stamp or from sstate. The artifact is
# still properly encrypted, just to the wrong holder, and nothing in the build
# output says so. That matters most in exactly the case you least want it: a
# compromise response that silently does not take effect.
#
# meta-rauc already does this for the SIGNING identity
# (bundle.bbclass: RAUC_CERT_FILE / RAUC_KEY_FILE); the encryption recipient
# needs the same treatment. rauc's cms_encrypt() reads the recipient file with
# load_certs_from_file() and envelopes to every certificate in it, so the
# file's bytes decide who can decrypt.
#
# NOT VERIFIED end to end: `bitbake -S none` reports no file_checksum_values
# for do_bundle -- for these entries AND for meta-rauc's pre-existing ones --
# and a content-only change did not move the dumped taskhash. That is most
# likely the dump mode not gathering manually-declared file-checksums rather
# than the flag being inert, but it was not proven either way; proving it needs
# a real bundle build against rotated key material. Landed regardless: it is
# the upstream-sanctioned mechanism and can only make the signature more
# sensitive, never less. If it turns out to be inert here, meta-rauc's signing
# -identity protection is inert too, which is worth chasing separately.
#
# The keyring is deliberately NOT listed: `rauc encrypt --keyring=` only gates
# whether encryption is allowed to proceed, it does not shape the artifact.
#
# Emitted only when the variable is non-empty. It is NOT emptied by the verity
# opt-out -- it derives from RAUC_OTA_CA_DIR independently of the toggle -- but
# it is empty when RAUC_OTA_CA_DIR is unset, and a bare ":False" is not a valid
# file-checksums entry. Hashing it in the verity case too is deliberate: the
# only cost is an unnecessary rebuild if the certificate rotates, and erring
# toward rebuilding is the right bias for a property about who can decrypt.
do_bundle[file-checksums] += "${@('%s:False' % (d.getVar('IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS') or '').strip()) if (d.getVar('IOTGW_RAUC_BUNDLE_ENCRYPT_RECIPIENTS') or '').strip() else ''}"

# Independent confirmation of what was actually deployed.
#
# Everything above is this build reasoning about its own configuration. This
# asks the artifact instead, via the same `rauc info` an operator would run.
# No decryption key is needed to tell the three states apart:
#
#   enveloped crypt -> rauc refuses with "Encrypted bundle detected"
#   plain crypt     -> "Bundle Format: crypt [unencrypted CMS]" — rauc labels
#                      this state explicitly (verified against a hand-built
#                      specimen). The check keys off the ABSENCE of
#                      "[encrypted CMS]" rather than that literal, so any
#                      unrecognised crypt sub-state also lands here and is
#                      refused. This is the dangerous state: the payload key
#                      is readable in the plain manifest.
#   verity          -> "Bundle Format: verity"
#
# A mismatch deletes the artifact. Publishing a bundle of unknown format is
# worse than publishing none.
do_deploy:append() {
    deployed="${DEPLOYDIR}/${BUNDLE_NAME}${BUNDLE_EXTENSION}"
    info_out=""

    if [ ! -f "$deployed" ]; then
        bbfatal "Deployed bundle missing, cannot verify format: $deployed"
    fi

    # rauc colourises the format suffix even when stdout is not a tty; strip
    # the escapes so the greps below match the text and not the colour codes.
    info_out="$(${STAGING_BINDIR_NATIVE}/rauc info --no-verify "$deployed" 2>&1 | sed -e 's/\x1B\[[0-9;]*[a-zA-Z]//g' || true)"

    if [ "${IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION}" = "1" ]; then
        if ! printf '%s\n' "$info_out" | grep -q "Encrypted bundle detected"; then
            rm -f "$deployed" "${DEPLOYDIR}/${BUNDLE_LINK_NAME}${BUNDLE_EXTENSION}"
            bbfatal "Deployed bundle is NOT an encrypted crypt bundle, artifact removed. rauc info said:\n$info_out"
        fi
        bbnote "Bundle format verified: crypt [encrypted CMS] — $deployed"
    else
        if ! printf '%s\n' "$info_out" | grep -qE "Bundle Format:[[:space:]]*verity"; then
            rm -f "$deployed" "${DEPLOYDIR}/${BUNDLE_LINK_NAME}${BUNDLE_EXTENSION}"
            bbfatal "Deployed bundle is not the expected verity format, artifact removed. rauc info said:\n$info_out"
        fi
        bbnote "Bundle format verified: verity (encryption opted out) — $deployed"
    fi
}

do_deploy[vardeps] += "IOTGW_ENABLE_RAUC_BUNDLE_ENCRYPTION"
