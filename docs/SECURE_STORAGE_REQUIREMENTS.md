# Secure Storage — Requirements and Architecture

**Status:** Requirements
**Scope:** Hardware-backed secret storage, device identity, disk encryption, and attestation on RPi5
**Related docs:** [TPM_REQUIREMENTS.md](TPM_REQUIREMENTS.md) · [SECURITY.md](SECURITY.md) · [THREAT_MODEL.md](THREAT_MODEL.md)
**tpm-ops repo:** `~/GitRepos/tpm-ops` (v0.2.0 — persistent keys + sign/verify complete)

---

## 1. Why This Matters

The current image has a structural gap: secrets are protected by file permissions (`0600`, `0640`) and systemd
credential files on an overlayfs-backed `/etc`. There is no hardware-binding. An attacker who clones the SD
card and boots it on a different machine gets all secrets verbatim. A stripped or re-imaged device that
re-provisioned from the same `/data/iotgw/` source becomes indistinguishable from the original.

We have an Infineon SLB9672 TPM2 on SPI. The chip can fix this:

- A secret sealed to TPM PCR state is unreadable if the firmware or kernel changes.
- A private key that lives inside the TPM cannot be exported — signing happens inside silicon.
- A monotonic NV counter inside the TPM cannot be decremented — firmware rollback becomes detectable.
- A TPM Quote proves to a remote server that a specific device ran a specific, unmodified firmware.

For this platform, TPM2 is the hardware root of trust for key protection,
sealing, anti-rollback, and attestation.

---

## 2. Current State

| Capability | Status |
|---|---|
| TPM kernel driver (SLB9672 SPI) | ✅ Behind `IOTGW_ENABLE_TPM_SLB9672=1` |
| `/dev/tpmrm0` access policy (`iotgwtpm` user/group, udev rules, TCTI defaults) | ✅ `iotgw-tpm-policy` recipe |
| `tpm-ops` CLI (info, selftest, random, PCR read, hash, sign, verify, key management) | ✅ v0.2.0 |
| Persistent signing keys (RSA-2048, ECC P-256) under SRK | ✅ v0.2.0 |
| Seal / unseal (bind secret to PCR state) | ✗ tpm-ops Phase 3 |
| PCR policy sessions (key only usable if PCRs match) | ✗ tpm-ops Phase 4 |
| Attestation (TPM Quote for remote verification) | ✗ tpm-ops Phase 5 |
| NV storage / monotonic anti-rollback counters | ✗ tpm-ops Phase 7 |
| `/data` partition encryption (LUKS + TPM unseal) | ✗ Not implemented |
| OTA device identity key hardware-bound to TPM | ✗ Currently plain file `/etc/ota/device.key` |
| systemd `SetCredentialEncrypted=` (TPM-sealed credstore) | ✗ systemd compiled `-TPM2` |
| `tpm2-openssl` provider (OpenSSL apps use TPM key directly) | ✗ Not in layer |

---

## 3. Use Cases

### UC1 — Sealed Disk Encryption for `/data`

**Threat addressed:** SD card cloning. An attacker who physically removes the SD card from a deployed gateway
and mounts it on another machine reads `/data` in plaintext — OTA certs, overlayfs upper contents, logs,
MQTT credentials backup.

**Mechanism:** LUKS2 keyslot sealed to TPM PCR state via `systemd-cryptenroll`.

```
At first provisioning:
  cryptsetup luksFormat /dev/mmcblk0p5
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/mmcblk0p5

At every boot:
  /etc/crypttab → systemd-cryptsetup → TPM2 unseal → mount /data
```

PCR 0 covers firmware integrity; PCR 7 covers secure boot configuration. If either changes (e.g., the card is
moved to a different board with different firmware, or the bootloader is modified), the TPM refuses to unseal.
The passphrase fallback for recovery is stored offline with the device's provisioning material.

**Dependencies:**
- TPM driver enabled
- `cryptsetup` + `tpm2-tss` in base image
- systemd `sd-encrypt` module in initramfs (or early boot hook)
- WKS partition change: `/data` becomes a LUKS container
- Provisioning: first-boot setup step after OTA cert provisioning

**Constraints:**
- PCR values must be stable across OTA updates. RAUC A/B slot switch changes the active rootfs but must not
  change PCR 0 or 7. Validate this on hardware before enforcing.
- A failed unseal at boot means `/data` is inaccessible — gateway cannot function. Recovery procedure
  (enter passphrase via console) must be documented.

---

### UC2 — Hardware-Bound Device Identity for OTA (mTLS)

**Threat addressed:** Device impersonation. The current `device.key` is a `0640 root:ota` file. It can be
copied from a compromised device and used to authenticate as that device from anywhere.

**Mechanism:** ECC P-256 signing key created inside TPM, never exported. OTA updater uses `tpm2-openssl`
provider so OpenSSL calls route through the TPM for the TLS handshake private-key operation.

```
At manufacturing / first provisioning:
  tpm-ops key create --algo ecc --persist 0x81000001
  tpm-ops key export-pub 0x81000001 > /tmp/device_pub.pem
  # CSR signed offline by fleet CA → device.crt delivered back to device

At OTA update time:
  ota-update-check → OpenSSL mTLS → tpm2-openssl provider → sign TLS handshake inside TPM
```

The file `/etc/ota/device.key` is replaced by the TPM handle reference. The `device.crt` remains a plain file
(public material, no sensitivity). The private key cannot be extracted even by root.

**Dependencies:**
- `tpm-ops key create` (✅ done)
- `tpm2-openssl` Yocto recipe added to layer
- `ota-update-check` modified to configure OpenSSL with the tpm2-openssl provider URI
  (`tpm2:handle=0x81000001` or via `OPENSSL_CONF` pointing to a TPM2 provider config)
- Fleet CA workflow: accepts CSR, issues device cert, returns `device.crt`
- Handle `0x81000001` reserved as the device identity key (document this in the layer)

**Note on tpm2-pkcs11 vs tpm2-openssl:**
PKCS#11 adds a daemon (`tpm2-pkcs11`), a database, and a PKCS#11 URI layer. For our specific use case
(one TLS client, one key), `tpm2-openssl` is the right level — it plugs directly into OpenSSL as a
provider, no daemon, no extra state. PKCS#11 is worth reconsidering only if we need the same key used
by multiple applications with different auth policies.

---

### UC3 — Anti-Rollback Counters for RAUC Bundles

**Threat addressed:** Firmware downgrade. An attacker who obtains a signed RAUC bundle from an older
(vulnerable) firmware version replays it. RAUC verifies the signature but has no way to reject a valid older
bundle.

**Mechanism:** TPM2 NV monotonic counter incremented after each successful OTA install. RAUC pre-install hook
checks that the bundle's declared version is above the current counter value. Counter is inside TPM — cannot
be decremented, survives rootfs wipe.

```
NV index 0x01500001 → RAUC bundle version counter (u64, increment-only)

RAUC bundle hook (pre-install):
  current_counter=$(tpm-ops nv read-counter --index 0x01500001)
  bundle_version=$(rauc info --output-format=json | jq .version)
  [ "$bundle_version" -gt "$current_counter" ] || exit 1  # reject downgrade

RAUC bundle hook (post-mark-good):
  tpm-ops nv counter increment --index 0x01500001
```

**Dependencies:**
- tpm-ops Phase 7 (NV storage + counter)
- RAUC bundle metadata must carry a monotonic version field (independent of SemVer)
- Policy decision: fail-open (warn but allow) vs fail-closed (hard reject) for first deployment

**Constraints:**
- Counter initialization at manufacturing/first-boot is a one-time operation. Once incremented, it
  cannot be reset without TPM owner clear (which also clears all keys and sealed data).
- Policy must handle factory reset / RMA: document the authorized `tpm2_clear` recovery path.

---

### UC4 — Remote Attestation for Fleet Verification

**Threat addressed:** Compromised device in fleet. A gateway running modified firmware could exfiltrate
sensor data or inject false readings. The fleet management backend has no way to verify device integrity
without attestation.

**Mechanism:** Attestation Key (AK) in TPM signs a Quote (PCR snapshot + nonce). The backend verifies the
Quote against known-good PCR values for the expected firmware version.

```
Device side:
  tpm-ops attest create-ak --persist 0x81010001
  tpm-ops key export-pub 0x81010001 > ak_pub.pem
  # AK public key enrolled with fleet backend at provisioning time

Challenge/response (periodic or on-connect):
  nonce=$(fleet-backend issue-nonce --device-id $DEVICE_ID)
  quote=$(tpm-ops attest quote --ak 0x81010001 --pcrs 0,1,7 --nonce $nonce)
  fleet-backend verify-quote --device-id $DEVICE_ID --quote $quote --nonce $nonce

Backend checks:
  - Signature valid for enrolled AK public key
  - Nonce matches (replay prevention)
  - PCR values match expected golden measurements for image version X.Y.Z
```

**Dependencies:**
- tpm-ops Phase 5 (TPM Quote)
- Golden PCR measurement database in fleet backend (per image version, per machine type)
- AK enrollment workflow at provisioning time
- This use case has no Yocto layer changes — purely tpm-ops + backend work

**Note:** Attestation is only meaningful if PCR measurements are stable and well-understood.
UC1 (sealed disk) requires PCR stability analysis. Attestation needs the same. Both should share
the PCR policy definition work.

---

### UC5 — TPM-Sealed systemd Credentials (Future)

**Threat addressed:** Offline credential extraction. Currently `/etc/credstore/` files are `0600 root:root`
on overlayfs. Root can read them; a cloned SD card exposes them without hardware.

**Mechanism:** `systemd-creds encrypt --tpm2-device=auto` seals credential files to the TPM. The systemd
unit uses `SetCredentialEncrypted=` instead of `LoadCredential=`. Decryption requires the TPM — works only
on the original hardware.

**Current blocker:** systemd on this image is compiled `-TPM2 -OPENSSL -GCRYPT`. `SetCredentialEncrypted=`
is unavailable without recompiling systemd with `+TPM2`.

**Options:**
1. Rebuild systemd with `PACKAGECONFIG:append:pn-systemd = " tpm2"` — adds `libtss2-dev` dependency,
   increases systemd binary size, unlocks `SetCredentialEncrypted=` and `systemd-cryptenroll`
2. Manual HKDF-based key derivation: at boot, derive a symmetric key from a TPM-sealed seed, use it to
   decrypt credential files stored encrypted on `/data` — more complex, no systemd integration
3. Accept current posture: credstore files protected by filesystem permissions + LUKS `/data` (UC1 provides
   the at-rest protection layer)

**Recommendation:** Option 1 (rebuild systemd with `+TPM2`) is the right long-term path. It enables both
`SetCredentialEncrypted=` and `systemd-cryptenroll` (needed for UC1 anyway — currently `systemd-cryptenroll`
is the intended tool for TPM2 LUKS enrollment). Both use cases are unblocked by the same recompile.

---

## 4. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ IoT Gateway — Hardware-Backed Security Architecture                 │
├───────────────────┬─────────────────────────────────────────────────┤
│ Layer             │ Mechanism                                        │
├───────────────────┼─────────────────────────────────────────────────┤
│ Disk at rest      │ LUKS2 /data, keyslot sealed to PCR 0+7 in TPM  │
│                   │ → SD card clone is ciphertext without the TPM   │
├───────────────────┼─────────────────────────────────────────────────┤
│ Device identity   │ ECC P-256 at TPM 0x81000001 (non-exportable)   │
│                   │ → mTLS OTA auth, key never leaves silicon        │
├───────────────────┼─────────────────────────────────────────────────┤
│ Runtime secrets   │ Today: systemd credentials (/etc/credstore)     │
│                   │ Future: SetCredentialEncrypted= (systemd +TPM2) │
│                   │ → sealed, hardware-bound at rest                 │
├───────────────────┼─────────────────────────────────────────────────┤
│ Firmware rollback │ NV counter at 0x01500001 checked by RAUC hook  │
│ prevention        │ → monotonic, TPM-internal, cannot be decremented│
├───────────────────┼─────────────────────────────────────────────────┤
│ Fleet integrity   │ AK at 0x81010001, TPM Quote on PCR 0,1,7       │
│                   │ → backend verifies device runs expected firmware │
└───────────────────┴─────────────────────────────────────────────────┘

TPM handle reservation:
  0x81000000  SRK (Storage Root Key — created by tpm-ops, do not delete)
  0x81000001  Device Identity Key (ECC P-256, OTA mTLS — UC2)
  0x81010001  Attestation Key (AK, restricted signing — UC4)
  0x01500001  Anti-rollback NV counter (RAUC bundle version — UC3)
```

### Dependency chain

```
UC1 (LUKS)  ─────────────┐
                          ├──→ Requires: systemd +TPM2 recompile
UC5 (credstore encrypt) ──┘               ↓
                               Enables: systemd-cryptenroll + SetCredentialEncrypted=

UC2 (device identity) ──→ Requires: tpm2-openssl in layer + OTA client change

UC3 (anti-rollback) ──→ Requires: tpm-ops Phase 7 (NV) + RAUC hook change

UC4 (attestation) ──→ Requires: tpm-ops Phase 5 (Quote) + backend work
                  ──→ Benefits from UC1 PCR stability analysis
```

---

## 5. RPi5 Security Mapping

This section maps each design goal to the implementation approach on this
platform:

| Security goal | RPi5 / SLB9672 approach | Gap |
|---|---|---|
| Hardware-bound root for secrets | TPM2 primary seed and persistent objects | None |
| Secrets unusable off-device | LUKS keyslot sealed to TPM PCR | Requires UC1 implementation |
| Non-exportable device identity key | TPM key handle + `tpm2-openssl` provider | Requires UC2 implementation |
| Runtime key isolation | TPM hardware boundary (key material remains in TPM) | Root can invoke TPM APIs |
| Provisioning workflow for identity | First-boot `tpm-ops key create` + `iotgw-provision.sh` | Needs workflow design |
| Encrypted durable storage | LUKS `/data` + TPM-sealed credstore | Requires UC1 + UC5 implementation |
| Anti-cloning and rollback resistance | TPM + PCR-sealed material + NV counter | Requires UC1 + UC3 implementation |

TPM2 provides the core security property for these use cases: sealed secrets and
private keys are bound to this specific hardware and private key material is not
exportable.

---

## 6. What Is Out of Scope

- **PKCS#11 daemon (`tpm2-pkcs11`)**: Adds operational complexity (token database, `tpm2-ptool`
  provisioning). Our use cases are solved more cleanly by `tpm2-openssl` for TLS and direct `tss-esapi`
  for tpm-ops. Revisit only if multiple applications need PKCS#11 URIs.
- **Encrypted sessions (TPM bus parameter encryption)**: The SLB9672 is on an RP1-internal SPI bus.
  Physical bus sniffing requires board-level access. Encrypted sessions are left for future hardening
  if the threat model changes. Tracked in tpm-ops Bonus Ideas.
- **Full remote attestation backend**: UC4 defines the device-side interface. Backend implementation
  (PCR golden database, challenge API) is outside this repository.
- **Key duplication / fleet provisioning key migration**: Each device generates its own identity key
  on-device at first boot. No key injection from manufacturing tooling required.

---

## 7. Implementation Phases

Each phase is independently testable on hardware. Later phases depend on earlier ones only where noted.

### Phase A — Enable systemd TPM2 support (blocker for UC1, UC5)

**Yocto change:** Rebuild systemd with TPM2 + cryptographic backend.

```bitbake
# In kas/local.yml or distro include
PACKAGECONFIG:append:pn-systemd = " tpm2 openssl"
DEPENDS:append:pn-systemd = " libtss2 openssl"
```

**Acceptance:**
- `systemctl --version` shows `+TPM2 +OPENSSL`
- `systemd-cryptenroll --help` works
- `systemd-creds encrypt --tpm2-device=auto` works

**Note:** This is a significant rebuild (systemd is a core package). Test full boot, OTA install, and
service starts on hardware before merging.

---

### Phase B — Sealed /data encryption (UC1)

Depends on Phase A.

**Steps:**
1. WKS change: `/data` partition formatted as LUKS2 at image build time or first-boot format script.
2. First-boot provisioning: `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7` enrolls TPM2
   keyslot. Passphrase keyslot kept for recovery (stored in per-device provisioning record).
3. `/etc/crypttab` entry for auto-unseal at boot.
4. Validate PCR stability across OTA slot switch (RAUC A→B→A without breaking unseal).
5. Document recovery procedure (console passphrase entry + TPM re-enroll after legitimate firmware change).

**Acceptance:**
- Cold boot unseals and mounts `/data` without user interaction.
- Booting the SD card in a different RPi5 (different board-level PCR 0) fails to unseal.
- RAUC install + reboot succeeds and `/data` re-unseals on the new slot.

---

### Phase C — tpm-ops: Seal / Unseal + PCR policy (tpm-ops Phases 3+4)

Independent of Phase A/B. Work happens in `~/GitRepos/tpm-ops`.

**Adds to tpm-ops:**
```
tpm-ops seal <data> --pcrs 0,7 --out sealed.bin
tpm-ops unseal sealed.bin --pcrs 0,7
tpm-ops key create --algo ecc --policy-pcrs 0,7 --persist 0x81000001
```

**Gateway payoff:** Phase C gives us the primitives needed for UC3 and UC4, and provides a manual
alternative to `systemd-cryptenroll` if Phase A is delayed.

---

### Phase D — Hardware-bound OTA device identity (UC2)

Depends on Phase C (persistent key creation is already done in v0.2.0; PCR-policy binding from Phase C
is optional for initial UC2 implementation).

**Steps:**
1. Add `tpm2-openssl` recipe to `meta-iot-gateway`.
2. First-boot: `tpm-ops key create --algo ecc --persist 0x81000001` creates device identity key.
3. Generate CSR: `openssl req -provider tpm2 -key "handle:0x81000001" -new -out device.csr`.
4. Fleet CA signs CSR → `device.crt` returned to device (out of scope for this repo).
5. `ota-update-check` configured with `OPENSSL_CONF` pointing to tpm2-openssl provider config.
6. `ota-certs-provision.sh` updated: check for `device.key` file vs TPM handle presence; skip key
   file provisioning if handle `0x81000001` is already populated.

**Acceptance:**
- `openssl s_client` mTLS handshake to OTA server succeeds using TPM key at `0x81000001`.
- `tpm-ops key list` shows `0x81000001` is ECC P-256.
- No `device.key` file exists in `/etc/ota/`.

---

### Phase E — Anti-rollback NV counters (UC3)

Depends on tpm-ops Phase 7 (NV storage).

**Steps:**
1. tpm-ops adds `nv` subcommands (counter create, increment, read).
2. First-boot provisioning initializes counter at `0x01500001` with value 0.
3. RAUC bundle manifest gets a `[version]` field with a monotonic integer.
4. RAUC pre-install hook: read counter, compare with bundle version, reject if ≤ current.
5. RAUC post-mark-good hook: increment counter.

---

### Phase F — Remote attestation (UC4)

Depends on tpm-ops Phase 5 (TPM Quote). Backend work is external.

**Steps:**
1. tpm-ops adds `attest` subcommands (create-ak, quote, verify).
2. AK provisioned at `0x81010001` during first-boot.
3. AK public key exported and enrolled with fleet backend.
4. Attestation client script / service: request nonce → generate quote → POST to backend.

---

## 8. PCR Allocation Policy

Defining PCR ownership is required before Phase B (sealing) and Phase F (attestation) can be designed
precisely. The following is the intended policy — validate actual values on hardware before finalizing.

| PCR | Measured by | Content | Used for sealing? |
|---|---|---|---|
| 0 | RPi firmware | Firmware code (UEFI / VideoCore) | Yes — UC1, UC4 |
| 1 | RPi firmware | Firmware configuration | No (too variable) |
| 4 | RPi firmware / U-Boot | Boot manager code | Monitor |
| 7 | RPi firmware | Secure boot state | Yes — UC1, UC4 |
| 8 | U-Boot / FIT | FIT image hash | Future — after measured boot |
| 9 | U-Boot / FIT | Kernel command line | Future |
| 23 | Reserved for application use | User-defined measurements | Future |

**Immediate action needed:** Run `tpm-ops pcr --index 0..7` before and after an OTA slot switch to
confirm PCR 0 and PCR 7 are stable across RAUC A↔B transitions. If they change on slot switch,
sealing policy must use different PCRs.

---

## 9. Open Questions

1. **PCR stability across OTA**: Do PCR 0 and 7 change when RAUC switches the active slot? Must be
   measured on hardware. Drives sealing PCR selection for UC1 and UC4.

2. **First-boot vs manufacturing provisioning**: UC2 assumes the device identity key is created on-device
   at first boot. If device certificates need to be issued before shipment (to avoid internet dependency
   at customer site), a manufacturing provisioning workflow needs design. Out of scope for now.

3. **Recovery procedure for broken unseal (UC1)**: A legitimate firmware update that changes PCR 0 or 7
   will break LUKS unseal. The operator must enter a passphrase and re-enroll the TPM keyslot.
   Automating this re-enrollment as part of the RAUC post-install hook (before reboot) would be safer
   than requiring console access. Needs design.

4. **systemd +TPM2 binary size impact**: Adding `+TPM2 +OPENSSL` to systemd adds libtss2 and libssl
   as runtime deps. Measure the image size delta on a full build before committing.

5. **RAUC bundle version field**: RAUC's bundle manifest (`[bundle]` section) does not natively include
   a monotonic integer version for anti-rollback. Need to determine whether to use the `[version]`
   field, a custom manifest entry, or a side-channel (separate signed metadata blob) for UC3.

---

## 10. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-04-04 | tpm2-openssl preferred over tpm2-pkcs11 for OTA mTLS | Simpler stack; PKCS#11 daemon overhead not justified for single-key use case |
| 2026-04-04 | systemd +TPM2 recompile required (Phase A) | Needed for systemd-cryptenroll (UC1) and SetCredentialEncrypted= (UC5); single rebuild unblocks both |
| 2026-04-04 | /data LUKS + PCR sealing (UC1) is highest-priority use case | Addresses SD card clone threat across all stored secrets, not just OTA certs |
| 2026-04-04 | PCR stability validation is a prerequisite before sealing work | Sealing to unstable PCRs would brick /data across every OTA update |
| 2026-04-04 | Device identity key generated on-device at first boot, not injected at manufacturing | Avoids manufacturing tooling dependency; acceptable for current fleet size |
