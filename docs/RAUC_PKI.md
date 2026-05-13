# RAUC PKI: YubiKey-Resident Root CA + Chain-Rooted Bundle Signing

This guide covers the IoT Gateway RAUC PKI: a three-tier X.509 hierarchy
rooted in two hardware-resident Root CAs (one per YubiKey, dual-trust for
disaster recovery), with file-based intermediate CAs and an annual code-
signing leaf. Bundles are signed via PKCS#11 against the operator's
YubiKey; devices verify the signature chain against trust anchors
installed under `/etc/rauc/keyring.d/`.

The doc is both architecture reference and operator runbook. All concrete
serial numbers and PINs are replaced with placeholders — the trust model
is public, the hardware inventory is operator-local.

## Trust Model

### What the design protects against

- **Bundle signing key extraction.** The Root CA private key lives in a
  YubiKey PIV slot with `PIN ALWAYS` + `touch ALWAYS` policy. PKCS#11
  exposes only the signing operation; the key material is not exportable
  through any documented interface. An attacker with file-system access
  to the operator's build host cannot exfiltrate the Root key.
- **Compromised signing leaf.** Leaves expire after one year and are
  re-issued from the file-based Dev CA without touching the Root. If a
  leaf is suspected compromised, the next bundle release rotates it; the
  device side doesn't need a keyring update because chain trust holds.
- **Compromised single Root.** The device keyring directory trusts
  *both* Roots. A bundle signed under the surviving Root will install on
  every device. The compromised YubiKey can be physically destroyed and
  replaced without re-flashing the fleet.
- **Adversary-issued bundles.** Devices reject any bundle whose
  signature does not chain to a Root in `/etc/rauc/keyring.d/`. Optional
  `check-purpose=codesign` and `allowed-signer-cns=` gates add CN
  allowlisting and X.509 purpose enforcement on top of chain trust.

### What it does NOT protect against (Stage 1 residual risks)

- **File-based intermediate CA compromise.** The Dev/Prod intermediate
  CA private keys live on the build host's filesystem (`0600` ownership,
  but recoverable by any process running as the operator). An attacker
  who roots the build host can sign new leaves under the Dev/Prod CA
  without ever touching the YubiKey. **This is the explicit residual
  risk closed by a follow-on phase** that promotes Dev/Prod CA private
  keys into YubiKey PIV slots 9d/82.
- **Physical YubiKey + PIN attack.** A stolen YubiKey with three PIN
  attempts is locked out (and PUK has its own three-attempt limit). The
  dual-Root design assumes physical compromise of only one of the two
  YubiKeys — keep them in separate physical locations.
- **Build host compromise yielding pre-signed bundles.** An attacker who
  reaches the operator's interactive session during a signing operation
  can submit alternate CSRs to the YubiKey within the same PIN session.
  Touch policy `ALWAYS` mitigates this somewhat (every signature
  requires the operator's physical touch), but the operator must remain
  attentive to unexpected PIN/touch prompts.
- **Device key compromise.** The OTA mTLS device keys live in a
  separate trust domain and are out of scope for this document. See
  `OTA_UPDATE.md`.

## PKI Hierarchy

```
                ┌──────────────────────────────────────────┐
                │  Two Root CAs (one per YubiKey, slot 9c) │
                │  P-384, 20 yr validity, on-device key    │
                │  Subject: iotgw-rauc-root-ca-2026-{role} │
                └─────────────────┬────────────────────────┘
                                  │ signs (PIN+touch each time)
                ┌─────────────────┴────────────────────────┐
                │                                          │
                ▼                                          ▼
        ┌───────────────┐                          ┌───────────────┐
        │  Dev CA       │                          │  Prod CA      │
        │  P-256, 3 yr  │                          │  P-256, 3 yr  │
        │  File-based   │                          │  File-based   │
        └───────┬───────┘                          └───────┬───────┘
                │ signs                                    │ signs
                ▼                                          ▼
        ┌───────────────┐                          ┌───────────────┐
        │  Dev signer   │                          │  Prod signer  │
        │  P-256, 1 yr  │                          │  P-256, 1 yr  │
        │  codeSigning  │                          │  codeSigning  │
        │  File-based   │                          │  File-based   │
        └───────────────┘                          └───────────────┘
                │                                          │
                ▼                                          ▼
          RAUC bundle CMS signature              RAUC bundle CMS signature
          (one chain attached per bundle)        (one chain attached per bundle)
```

### Algorithm choices

| Tier | Algorithm | Digest | Validity |
|---|---|---|---|
| Root CA | ECDSA P-384 | SHA-384 | 20 years |
| Intermediate CA | ECDSA P-256 | SHA-384 (Root-signed) | 3 years |
| Signing leaf | ECDSA P-256 | SHA-256 (Dev-CA-signed) | 1 year |

P-384 for the Root and P-256 for the rest is conservative-but-pragmatic:
P-384 gives the Root extra margin for its long validity window and
expected longevity through any future P-256→PQ migration; P-256 for
intermediates and leaves matches YubiKey 5-series performance and keeps
RAUC bundle CMS signatures compact.

The 20/3/1-year validity ladder is the standard offline-Root + rotating-
intermediate pattern. Short leaf lifetime is the primary mechanism that
self-heals from leaf compromise without active CRL infrastructure.

## Hardware Foundation

| Component | Version | Purpose |
|---|---|---|
| YubiKey 5C NFC | firmware 5.7.4 | PIV applet, two devices for dual-Root |
| libykcs11 | 2.7.3 (built from source) | PKCS#11 module exposing PIV slots |
| pkcs11-provider | 0.3 | OpenSSL 3 provider for PKCS#11 keys |
| OpenSSL | 3.0.13+ | Provider-aware signing operations |
| ykman | 5.x | PIV slot provisioning (key gen, cert import) |
| pcscd | active (socket-activated) | Smart-card daemon |

The libykcs11 path is `/usr/local/lib/libykcs11.so` (source-built rather
than distro-packaged because distro packages historically do not expose
the PIV retired slots 82–95 that this design uses for Stage 4 promotion).
`opensc-pkcs11.so` is present on most hosts but **not used** here — it
cannot enumerate retired slots.

### Operator-local inventory (never committed)

Operators record the following in their own vault, never in repo:

- The two YubiKey serial numbers (referred to in this doc as
  `${YK_PRIMARY_SERIAL}` and `${YK_BACKUP_SERIAL}`)
- The F9 attestation certs captured at provisioning time
- The PIN/PUK values

Suggested vault layout under `${RAUC_CA_DIR}` (e.g.
`~/rauc-keys/rauc-ca/`):

```
${RAUC_CA_DIR}/
├── root-ca/
│   ├── openssl-root.cnf
│   ├── openssl-root-backup.cnf
│   ├── openssl-ca-primary.cnf       # `openssl ca` config for Root signing
│   ├── root-ca-primary.crt          # exported Root cert (public)
│   ├── root-ca-primary.pub          # exported Root pubkey
│   ├── root-ca-backup.crt
│   ├── root-ca-backup.pub
│   ├── index.txt                    # `openssl ca` issuance database
│   ├── serial
│   ├── newcerts/                    # `openssl ca` cert copies
│   └── attestations/
│       ├── yk-${YK_PRIMARY_SERIAL}-9c-attest.crt
│       └── yk-${YK_BACKUP_SERIAL}-9c-attest.crt
├── dev-ca/
│   ├── openssl-dev-ca.cnf
│   ├── dev-ca.key.pem               # FILE-BASED — Stage 4 promotes to HSM
│   ├── dev-ca.csr
│   └── dev-ca.cert.pem
├── prod-ca/
│   ├── openssl-prod-ca.cnf
│   ├── prod-ca.key.pem
│   ├── prod-ca.csr
│   └── prod-ca.cert.pem
└── issued/dev/
    ├── openssl-dev-leaf.cnf
    ├── iotgw-rauc-dev-signer-2026.key.pem
    ├── iotgw-rauc-dev-signer-2026.csr
    └── iotgw-rauc-dev-signer-2026.cert.pem
```

The Root certs (`root-ca-{primary,backup}.crt`) are public and *will*
land in committed image bundles via the device keyring directory — but
they are not committed to the repo directly. The recipe consumes them at
build time via `IOTGW_RAUC_KEYRING_CERTS` (see below).

### Serial-anchored PKCS#11 URIs

With both YubiKeys plugged in simultaneously, bare `pkcs11:id=%02` is
ambiguous and the provider may select the wrong token. Every signing
operation in this doc uses a serial-anchored URI:

```
pkcs11:token=YubiKey%20PIV%20%23${YK_PRIMARY_SERIAL};id=%02;type=private
pkcs11:token=YubiKey%20PIV%20%23${YK_BACKUP_SERIAL};id=%02;type=private
```

`%23` is URL-encoded `#`, the prefix Yubico's libykcs11 uses in the
token label (e.g. `YubiKey PIV #<serial>`).

## Slot Reservation Map

PIV slots are assigned by purpose, not by which YubiKey holds them. Both
the primary and backup YubiKey use the same slot layout. The
`CKA_ID (hex)` column is the integer ykcs11 maps each PIV slot to (per
`ykcs11/objects.c`).

| Slot | CKA_ID | Role | Algorithm | PIN | Touch | Stage 1 status |
|---|---|---|---|---|---|---|
| 9c | 0x02 | RAUC Root CA (shared with sibling projects) | P-384 | ALWAYS | ALWAYS | **Key + cert provisioned** |
| 9d | 0x03 | RAUC Dev CA | (P-256) | — | — | Cert-only beacon (no key in slot) |
| 82 | 0x05 | RAUC Prod CA | (P-256) | — | — | Cert-only beacon |
| 83 | 0x06 | RAUC Dev signing leaf | (P-256) | — | — | Cert-only beacon |
| 9a | 0x01 | FIT image signing | — | — | — | Reserved (future) |
| 84–87 | 0x07–0x0a | Reserved for sibling project intermediates | — | — | — | Reserved |
| F9 | — | Yubico attestation (factory) | — | — | — | **Never touch** |

The cert-only beacons in 9d/82/83 carry the corresponding intermediate /
leaf cert without a matching on-device private key. Their purpose is
twofold: operator traceability (`ykman piv info` instantly reveals which
PKI tier each slot represents) and future-phase readiness (when a key
is generated into the slot later, the slot already advertises the
correct subject DN under the same operator workflow).

Slot F9 holds Yubico's factory-loaded attestation key. **Overwriting it
voids the attestation evidence chain.** It is read-only in this design.

## Provisioning Runbook

The runbook assumes:

- `${RAUC_CA_DIR}` resolves to your operator-local CA tree (e.g.
  `~/rauc-keys/rauc-ca`).
- `${YK_PRIMARY_SERIAL}` and `${YK_BACKUP_SERIAL}` are exported in your
  shell, set to the two YubiKey serials shown by `ykman list`.
- Only one YubiKey is plugged in at a time during each block, unless
  noted otherwise.

### Pre-flight checks

```bash
# Reader/process hygiene
systemctl is-active pcscd                          # expect: active
pgrep -a -f '^(scdaemon|gpg-agent|tio|minicom)'    # expect: nothing
ykman list                                         # expect: one YubiKey

# PKCS#11 stack
ls /usr/local/lib/libykcs11.so                     # expect: libykcs11.so → 2.7.3
pkcs11-tool --module /usr/local/lib/libykcs11.so --list-slots
openssl list -providers -provider pkcs11 -provider default
```

### Provisioning the primary Root CA (slot 9c)

Plug in the primary YubiKey alone, then:

```bash
mkdir -p ${RAUC_CA_DIR}/root-ca/attestations

# 1. Generate the Root key on-device (PIN + LED-blink touch)
ykman piv keys generate \
    --algorithm ECCP384 \
    --pin-policy ALWAYS \
    --touch-policy ALWAYS \
    9c ${RAUC_CA_DIR}/root-ca/root-ca-primary.pub
```

Write `${RAUC_CA_DIR}/root-ca/openssl-root.cnf`:

```ini
[req]
distinguished_name = req_dn
prompt             = no
utf8               = yes

[req_dn]
O  = IoT Gateway
OU = RAUC PKI
CN = iotgw-rauc-root-ca-2026-primary

[v3_root_ca]
basicConstraints       = critical, CA:TRUE, pathlen:1
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always

[v3_intermediate_ca]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
```

```bash
# 2. Self-sign the Root cert (sha384, 20 yr, two PIN prompts + one touch)
PKCS11_PROVIDER_MODULE=/usr/local/lib/libykcs11.so \
openssl req -x509 -new \
    -config ${RAUC_CA_DIR}/root-ca/openssl-root.cnf \
    -provider pkcs11 -provider default \
    -key "pkcs11:token=YubiKey%20PIV%20%23${YK_PRIMARY_SERIAL};id=%02;type=private" \
    -extensions v3_root_ca \
    -days 7305 \
    -sha384 \
    -out ${RAUC_CA_DIR}/root-ca/root-ca-primary.crt

# 3. Import the cert back into slot 9c (PIN, no touch)
ykman piv certificates import 9c ${RAUC_CA_DIR}/root-ca/root-ca-primary.crt

# 4. Capture the F9 attestation evidence (no PIN, no touch)
ykman piv keys attest 9c \
    ${RAUC_CA_DIR}/root-ca/attestations/yk-${YK_PRIMARY_SERIAL}-9c-attest.crt
```

### Provisioning the backup Root CA (slot 9c)

Unplug the primary, plug in the backup. If the backup's slot 9c is not
empty (residual key from earlier experiments), clear the cert first
(then the next `ykman piv keys generate` overwrites the old key
atomically):

```bash
ykman piv certificates delete 9c
```

Write `${RAUC_CA_DIR}/root-ca/openssl-root-backup.cnf` (identical to
`openssl-root.cnf` except the `req_dn` block uses
`CN = iotgw-rauc-root-ca-2026-backup` — distinct CN so the two Root
certs are individually identifiable in audit output).

Then repeat steps 1–4, swapping:

- `--out` path: `…/root-ca-backup.pub` and `…/root-ca-backup.crt`
- `-config`: `…/openssl-root-backup.cnf`
- PKCS#11 URI: `;token=YubiKey%20PIV%20%23${YK_BACKUP_SERIAL};`
- attestation filename: `yk-${YK_BACKUP_SERIAL}-9c-attest.crt`

The two Roots have **independent key pairs**. Distinct CNs do not break
trust — RAUC's keyring directory trusts by cert file, not by CN.

### Provisioning the file-based intermediate CAs and signing leaf

Plug the primary YubiKey back in (needed for Root signing of the two
intermediate CSRs).

#### File-based key + CSR generation (no YubiKey)

For each of Dev CA, Prod CA, Dev leaf, write the corresponding
`openssl-*.cnf` (with appropriate `req_dn` and, for the leaf, a
`[v3_leaf_signing]` extension block carrying
`keyUsage = digitalSignature` and
`extendedKeyUsage = codeSigning, emailProtection` — both EKUs are
required, see the "Known pitfalls" section), then:

```bash
# Per-subject key + CSR (P-256, software, mode 0600)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out ${RAUC_CA_DIR}/<subject>/<subject>.key.pem
chmod 0600 ${RAUC_CA_DIR}/<subject>/<subject>.key.pem
openssl req -new \
    -config ${RAUC_CA_DIR}/<subject>/openssl-<subject>.cnf \
    -key ${RAUC_CA_DIR}/<subject>/<subject>.key.pem \
    -out ${RAUC_CA_DIR}/<subject>/<subject>.csr
```

Subject DNs:

| Subject | OU | CN |
|---|---|---|
| Dev CA | `RAUC PKI rpi5` | `iotgw-rauc-dev-ca-2026` |
| Prod CA | `RAUC PKI rpi5` | `iotgw-rauc-prod-ca-2026` |
| Dev leaf | `RAUC PKI rpi5` | `iotgw-rauc-dev-signer-2026` |

#### Root-signing the two intermediate CSRs

`openssl x509 -req -CAkey <pkcs11-uri>` does **not** work with
pkcs11-provider 0.3 (the operation dispatcher returns "operation not
supported for this keytype"). Use `openssl ca` instead — it loads
private keys via the EVP_PKEY path that pkcs11-provider supports.

Scaffold the `openssl ca` state files once:

```bash
cd ${RAUC_CA_DIR}/root-ca
mkdir -p newcerts
touch index.txt
echo "01" > serial
```

Write `${RAUC_CA_DIR}/root-ca/openssl-ca-primary.cnf`:

```ini
[ca]
default_ca = primary_root

[primary_root]
certificate      = ${RAUC_CA_DIR}/root-ca/root-ca-primary.crt
private_key      = pkcs11:token=YubiKey%20PIV%20%23${YK_PRIMARY_SERIAL};id=%02;type=private
new_certs_dir    = ${RAUC_CA_DIR}/root-ca/newcerts
database         = ${RAUC_CA_DIR}/root-ca/index.txt
serial           = ${RAUC_CA_DIR}/root-ca/serial
default_md       = sha384
default_days     = 1095
policy           = policy_anything
email_in_dn      = no
copy_extensions  = none
unique_subject   = no
x509_extensions  = v3_intermediate_ca

[policy_anything]
countryName            = optional
stateOrProvinceName    = optional
localityName           = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[v3_intermediate_ca]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
```

Note: provider order matters. **Load `default` first**, then `pkcs11` —
otherwise pkcs11-provider grabs the CSR self-signature verification step
(which uses a file-based key) and fails with "invalid key handle":

```bash
# Sign Dev CA CSR (PIN x2 + one interactive y + one touch)
PKCS11_PROVIDER_MODULE=/usr/local/lib/libykcs11.so \
openssl ca \
    -config ${RAUC_CA_DIR}/root-ca/openssl-ca-primary.cnf \
    -provider default -provider pkcs11 \
    -extensions v3_intermediate_ca \
    -days 1095 \
    -in ${RAUC_CA_DIR}/dev-ca/dev-ca.csr \
    -out ${RAUC_CA_DIR}/dev-ca/dev-ca.cert.pem
# Repeat for prod-ca/prod-ca.csr → prod-ca/prod-ca.cert.pem
```

You will see two cosmetic error lines from pkcs11-provider during the
signing operation:

```
evp_pkey_get0_RSA_int: expecting an rsa key
p11prov_GetOperationState: …Error returned by C_GetOperationState
```

Both are non-fatal — pkcs11-provider attempts internal state-snapshot
operations that libykcs11 doesn't implement. The actual ECDSA signature
completes successfully; `index.txt` and the cert file are written.

#### Dev-CA-signing the leaf (no YubiKey)

```bash
openssl x509 -req \
    -in ${RAUC_CA_DIR}/issued/dev/iotgw-rauc-dev-signer-2026.csr \
    -CA ${RAUC_CA_DIR}/dev-ca/dev-ca.cert.pem \
    -CAkey ${RAUC_CA_DIR}/dev-ca/dev-ca.key.pem \
    -CAcreateserial \
    -extfile ${RAUC_CA_DIR}/issued/dev/openssl-dev-leaf.cnf \
    -extensions v3_leaf_signing \
    -days 365 \
    -sha256 \
    -out ${RAUC_CA_DIR}/issued/dev/iotgw-rauc-dev-signer-2026.cert.pem
```

### Cert-only imports into the primary YubiKey

```bash
ykman piv certificates import 9d ${RAUC_CA_DIR}/dev-ca/dev-ca.cert.pem
ykman piv certificates import 82 ${RAUC_CA_DIR}/prod-ca/prod-ca.cert.pem
ykman piv certificates import 83 ${RAUC_CA_DIR}/issued/dev/iotgw-rauc-dev-signer-2026.cert.pem
```

The slots now advertise their PKI role in `ykman piv info` even though
no private key sits behind them in this phase.

## Verification Recipe

### Per-cert sanity

```bash
openssl x509 -in <cert> -noout -text \
    | grep -E "Subject:|Issuer:|Signature Algorithm|Not (Before|After)|Public Key Algorithm|NIST CURVE|CA:|pathlen:|Key Usage|Code Signing"
```

Expected per tier:

| Cert | Signature alg | Public key | basicConstraints | EKU |
|---|---|---|---|---|
| Root | `ecdsa-with-SHA384` | P-384 | `CA:TRUE, pathlen:1` | — |
| Dev/Prod CA | `ecdsa-with-SHA384` | P-256 | `CA:TRUE, pathlen:0` | — |
| Dev signer | `ecdsa-with-SHA256` | P-256 | `CA:FALSE` | `Code Signing` |

### Chain validation

```bash
# Self-signed Root
openssl verify -CAfile root-ca-primary.crt root-ca-primary.crt
# Intermediates chain to primary Root
openssl verify -CAfile root-ca-primary.crt dev-ca.cert.pem
openssl verify -CAfile root-ca-primary.crt prod-ca.cert.pem
# Leaf chains via Dev CA to primary Root
openssl verify -CAfile root-ca-primary.crt \
    -untrusted dev-ca.cert.pem \
    issued/dev/iotgw-rauc-dev-signer-2026.cert.pem
```

All four must return `OK`.

### F9 attestation evidence

```bash
openssl x509 -in attestations/yk-${YK_PRIMARY_SERIAL}-9c-attest.crt \
    -noout -issuer -subject -serial
```

Expected issuer: `CN = YubiKey PIV Attestation` (Yubico's factory key).
Expected subject: `CN = YubiKey PIV Attestation 9c`. The cert serial
differs between the two YubiKeys — distinctness is the auditable proof
that the two Roots come from physically separate hardware.

### Slot inventory on the primary YubiKey

```bash
ykman piv info
```

Expected on primary after Stage 1 — four populated slots:

| Slot | Algorithm | Subject |
|---|---|---|
| 9C (SIGNATURE) | ECCP384 | `iotgw-rauc-root-ca-2026-primary` |
| 9D (KEY_MANAGEMENT) | ECCP256 | `iotgw-rauc-dev-ca-2026` |
| 82 (RETIRED1) | ECCP256 | `iotgw-rauc-prod-ca-2026` |
| 83 (RETIRED2) | ECCP256 | `iotgw-rauc-dev-signer-2026` |

The "Algorithm" line for 9D/82/83 reflects the cert's pubkey, not a
slot-resident key — those slots are cert-only beacons until a future
phase promotes their keys to HSM.

### Root issuance audit log

```bash
cat ${RAUC_CA_DIR}/root-ca/index.txt
```

Expected:

```
V    <expiry>    01    unknown    /O=IoT Gateway/OU=RAUC PKI rpi5/CN=iotgw-rauc-dev-ca-2026
V    <expiry>    02    unknown    /O=IoT Gateway/OU=RAUC PKI rpi5/CN=iotgw-rauc-prod-ca-2026
```

Two entries — exactly the two intermediates the Root has issued under
its lifetime. Any third entry without operator authorization is evidence
of unauthorized Root use.

### Bundle acceptance matrix (host-side, before deploy)

Before shipping bundles to the field, validate the trust model on the
build host by running `rauc info` against every keyring state a device
might be in. Three keyring states × two bundle signing modes = six cells;
the four `accept` cells are sanity checks and the two `reject` cells are
the load-bearing negative proofs that the cutover correctly excludes the
legacy chain and that M1 cannot skip the dual-trust transition.

`rauc info --keyring=PEMFILE` expects a single concatenated PEM file
(it does not enumerate a directory at runtime). Build the three keyring
PEMs once and reuse them:

```bash
# Legacy single-cert keyring (M1 device state)
cp ${IOTGW_RAUC_KEY_DIR}/dev-cert.pem  /tmp/keyring-legacy.pem

# Dual-trust keyring (M2 device state — transition)
cat ${IOTGW_RAUC_KEY_DIR}/dev-cert.pem \
    ${RAUC_CA_DIR}/root-ca/root-ca-primary.crt \
    ${RAUC_CA_DIR}/root-ca/root-ca-backup.crt \
    > /tmp/keyring-dual-trust.pem

# Roots-only keyring (M3 device state — cutover)
cat ${RAUC_CA_DIR}/root-ca/root-ca-primary.crt \
    ${RAUC_CA_DIR}/root-ca/root-ca-backup.crt \
    > /tmp/keyring-roots-only.pem
```

Then for each bundle (legacy-signed and chain-signed):

```bash
rauc info --keyring=<one-of-the-three-pems>.pem \
          --key=<encryption-private-key>.key \
          <bundle>.raucb
```

The `--key=` flag is required because bundles ship `crypt`-format
(encrypted CMS); without it `rauc info` errors out with
`Encrypted bundle detected, but no decryption key given.`

Expected results:

| Bundle (signer)         | vs Legacy keyring | vs Dual-trust | vs Roots-only |
|---|---|---|---|
| **M2 legacy-signed**    | ✓ accept (chain depth 1, `iot-gateway-rpi5`) | ✓ accept (legacy anchor still present) | ✗ **reject** — `Verify error: self-signed certificate` |
| **M3 chain-signed**     | ✗ **reject** — `unable to get local issuer certificate` | ✓ accept (chain depth 3, anchors on Root) | ✓ accept (chain depth 3, signer `iotgw-rauc-dev-signer-2026`) |

The two reject cells are the portfolio-gold negative tests:

- **Legacy bundle on cutover keyring**: proves that once a device boots
  into the Root-only state, no legacy-signed bundle can install. The
  legacy signer is retired by trust math, not by operator promise.
- **Chain bundle on legacy keyring**: proves that the migration order
  matters — an M1 device cannot skip the dual-trust transition image
  and jump straight to a chain-signed bundle. The trust ladder must be
  climbed one step at a time.

For each chain-signed accept, the chain breakdown rauc emits is itself
worth capturing for the portfolio evidence folder:

```
Certificate Chain:
 0 Subject: O = IoT Gateway, OU = RAUC PKI rpi5, CN = iotgw-rauc-dev-signer-2026
   Issuer:  O = IoT Gateway, OU = RAUC PKI rpi5, CN = iotgw-rauc-dev-ca-2026
 1 Subject: O = IoT Gateway, OU = RAUC PKI rpi5, CN = iotgw-rauc-dev-ca-2026
   Issuer:  O = IoT Gateway, OU = RAUC PKI,      CN = iotgw-rauc-root-ca-2026-primary
 2 Subject: O = IoT Gateway, OU = RAUC PKI,      CN = iotgw-rauc-root-ca-2026-primary
   Issuer:  O = IoT Gateway, OU = RAUC PKI,      CN = iotgw-rauc-root-ca-2026-primary
```

Subject==Issuer on entry 2 = self-signed Root. Chain anchors on the
keyring-trusted Root and terminates correctly.

## Device-Side Wiring (rpi5-iot-gw)

The recipe `rauc-conf-iotgw_1.0.bb` consumes three operator-local
variables to wire the device-side trust state:

| Variable | Purpose |
|---|---|
| `IOTGW_RAUC_KEYRING_CERTS` | Space-separated list of cert files installed into `/etc/rauc/keyring.d/`. Recipe runs `openssl rehash` on the destination. When set, `system.conf` renders `[keyring]` as `directory=/etc/rauc/keyring.d/`; when empty, falls back to the legacy `path=/etc/rauc/ca.cert.pem` single-cert mode. |
| `IOTGW_RAUC_ALLOWED_SIGNER_CNS` | Semicolon-separated CN allowlist. Empty = no CN restriction. |
| `IOTGW_RAUC_CHECK_PURPOSE` | OpenSSL X.509 purpose enforced on the signer chain (typically `codesign`). Empty = no purpose check. |

Bundle signing additionally consumes three meta-rauc variables. Note
the `--intermediate` plumbing: `rauc bundle --cert=` only ingests a
single leaf cert (concatenated chain PEMs are silently truncated to
their first cert), so intermediate CAs must be passed separately via
`BUNDLE_ARGS`. See pitfall §4 for the diagnostic story behind this.

Configure in `kas/local.yml`:

```yaml
local_conf_header:
  rauc_pki_chain: |
    # Bundle signing: leaf cert only in RAUC_CERT_FILE.
    # Intermediate(s) ride along via BUNDLE_ARGS --intermediate=
    # so they end up in the CMS signature alongside the leaf.
    RAUC_KEY_FILE     = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/issued/dev/iotgw-rauc-dev-signer-2026.key.pem"
    RAUC_CERT_FILE    = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/issued/dev/iotgw-rauc-dev-signer-2026.cert.pem"
    BUNDLE_ARGS       = "--intermediate=${IOTGW_RAUC_KEY_DIR}/rauc-ca/dev-ca/dev-ca.cert.pem"
    # Build-host trust anchor for the post-sign verification rauc bundle
    # runs internally — must complete the chain to a Root. The meta-rauc
    # default of `dev-cert.pem` is the legacy single-cert anchor and
    # cannot validate the new chain. See pitfall §5.
    RAUC_KEYRING_FILE = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-primary.crt"

    # Device-side trust anchors and runtime enforcement gates.
    IOTGW_RAUC_KEYRING_CERTS = " \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-primary.crt \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-backup.crt"
    IOTGW_RAUC_CHECK_PURPOSE = "codesign"
    IOTGW_RAUC_ALLOWED_SIGNER_CNS = "iotgw-rauc-dev-signer-2026"
```

After `rauc bundle` runs at build time, the resulting CMS signature
contains both the leaf (from `--cert=`) and the Dev CA (from
`--intermediate=`). Device-side chain verification then walks
`leaf → Dev CA → Root` against the trust anchors installed in
`/etc/rauc/keyring.d/`.

### Rendered `/etc/rauc/system.conf` (chain-rooted, with both gates enabled)

```ini
[keyring]
directory=/etc/rauc/keyring.d/
use-bundle-signing-time=true
check-purpose=codesign
allowed-signer-cns=iotgw-rauc-dev-signer-2026
```

## Field Rollout: Three-Image Migration

For devices already in the field running a legacy single-cert keyring
(`path=/etc/rauc/ca.cert.pem` with a self-signed dev cert), the rollout
to chain-rooted trust uses three images in sequence. Devices migrate via
OTA install without re-flashing.

### Image A — legacy steady state (already deployed)

`[keyring]` uses `path=`. Bundle is signed by the legacy single cert.
This is the current state of any field device. No change.

### Image B — dual-trust transition

`[keyring]` is `directory=`. `/etc/rauc/keyring.d/` contains *three*
trust anchors: the legacy `dev-cert.pem`, both new Roots. Bundle is
**still signed by the legacy key** so the Image-A device's legacy
keyring accepts the install.

Operator's `kas/local.yml` for this build:

```yaml
local_conf_header:
  rauc_pki_chain: |
    # Bundle stays on legacy signing key — the field device's existing
    # keyring is what we're trying to install against.
    RAUC_KEY_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-key.pem"
    RAUC_CERT_FILE = "${IOTGW_RAUC_KEY_DIR}/dev-cert.pem"
    # Device-side trust expands to legacy + both new Roots.
    IOTGW_RAUC_KEYRING_CERTS = " \
        ${IOTGW_RAUC_KEY_DIR}/dev-cert.pem \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-primary.crt \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-backup.crt"
    # Gates left empty — legacy cert has no codeSigning EKU and uses a
    # legacy CN, both of which would block the install path.
```

After install, the device boots into a state where it accepts **either**
a legacy-signed or a chain-signed bundle.

### Image C — chain-rooted steady state

`[keyring]` is `directory=`. `/etc/rauc/keyring.d/` contains *only* the
two new Roots. Bundle is signed under the new chain
(`leaf → Dev CA → primary Root`).

```yaml
local_conf_header:
  rauc_pki_chain: |
    RAUC_KEY_FILE     = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/issued/dev/iotgw-rauc-dev-signer-2026.key.pem"
    RAUC_CERT_FILE    = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/issued/dev/iotgw-rauc-dev-signer-2026.cert.pem"
    BUNDLE_ARGS       = "--intermediate=${IOTGW_RAUC_KEY_DIR}/rauc-ca/dev-ca/dev-ca.cert.pem"
    RAUC_KEYRING_FILE = "${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-primary.crt"
    IOTGW_RAUC_KEYRING_CERTS = " \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-primary.crt \
        ${IOTGW_RAUC_KEY_DIR}/rauc-ca/root-ca/root-ca-backup.crt"
    IOTGW_RAUC_CHECK_PURPOSE = "codesign"
    IOTGW_RAUC_ALLOWED_SIGNER_CNS = "iotgw-rauc-dev-signer-2026"
```

After install, the device rejects any legacy-signed bundle and accepts
only chain-rooted bundles whose leaf carries the
`codeSigning` EKU and a permitted CN.

### Rollback policy after cutover

| Rollback scenario | Outcome |
|---|---|
| Image C → legacy-signed bundle | **BLOCKED.** The legacy `dev-cert.pem` is no longer in the keyring directory, so a legacy-signed bundle has no trust anchor. This is intentional — the legacy signing key is retired permanently at the cutover. |
| Image C → older chain-signed bundle | **ALLOWED.** Any bundle signed under the same Root trust chain installs cleanly, regardless of which historical rootfs it carries. This is the supported rollback path. |

If a content-level rollback to an Image-A-shape rootfs is ever needed
after the cutover, re-sign the older rootfs with the new chain and
install that — release identity is the rootfs content, not the
signature.

## Disaster Recovery

### Primary YubiKey lost, stolen, or destroyed

1. **Confirm the loss.** Don't act on a "missing for a few hours"
   without trying to locate it first — every Root rotation is a fleet-
   wide event.
2. **Build a recovery bundle** signed under the backup Root chain. The
   recovery image's keyring directory contains *only* the backup Root.
3. Ship the recovery bundle over OTA. Devices currently trusting both
   Roots (steady-state Image C) accept the install because the signing
   chain anchors on the still-trusted backup Root.
4. **Physically destroy** the lost primary YubiKey if recovered, or
   accept the residual risk if not.
5. **Provision a fresh new-primary** in a new YubiKey (same procedure as
   Stage 1-A), and ship a follow-up bundle re-anchoring the keyring
   directory on `new-primary + backup` for redundancy. Optional: issue a
   fresh Dev CA under the new primary Root and rotate signing leaves.

### Backup YubiKey lost

Less urgent. Provision a fresh new-backup, ship a bundle re-anchoring
the keyring on `primary + new-backup`. The primary remains the active
signer throughout; no break in the bundle pipeline.

### Both YubiKeys lost

This is a re-bootstrap event. Devices in the field continue to install
*older* bundles whose chain still validates, but no new bundles can be
issued. Recovery requires either:

- Recovering the YubiKeys, or
- Physically re-flashing every device with a fresh image carrying a new
  Root set in its keyring directory.

This scenario is the principal reason for the two-physical-locations
rule on YubiKey storage.

## Re-key Policy

### Planned re-key triggers

Trigger on whichever fires first:

- **15 years after issuance.** Leaves 5 years of margin before the
  20-year validity expires — enough to ship a cutover image and
  decommission stragglers without expiry pressure.
- **Yubico EOL of the 5-series firmware.** Currently ~10 years post-
  release per Yubico's policy.
- **Mandatory PQ migration.** NIST has signaled ~2030–2035 timelines
  for post-quantum mandates. When the requirement lands, re-key the
  Root under a PQ-safe algorithm via a planned three-image migration.

### Unplanned re-key trigger

- **Suspected key compromise.** Treat as emergency. Procedure is
  identical to the disaster-recovery flow above: re-anchor on the
  surviving Root via an OTA-deliverable recovery bundle, destroy the
  compromised YubiKey, provision a replacement.

### Procedure

A planned re-key is the three-image migration in reverse order:

1. Provision the new Root in a new YubiKey.
2. Ship a bundle that adds the new Root to the keyring directory
   alongside the old (transition image).
3. Ship a bundle signed under the new chain whose keyring directory
   contains the new Root only (cutover image).
4. Decommission the old YubiKey.

## Out of Scope (Stage 4 preview)

A follow-on phase promotes the file-based Dev/Prod intermediate CA
private keys into the primary YubiKey's slots 9d/82, closing the residual
risk that the build host's filesystem holds intermediate signing keys.

Sketch of the migration:

1. Generate a fresh P-256 keypair into slot 9d on the primary YubiKey
   (PIN ALWAYS, touch CACHED for usability — intermediate signings happen
   in batches during routine leaf rotation, so touch caching is OK at
   the intermediate tier).
2. Build a new CSR for the same `iotgw-rauc-dev-ca-2026` subject DN
   (key changes; subject DN stays so leaves issued under the old key
   remain verifiable until they expire naturally).
3. Re-issue the Dev CA cert under the same Root primary YubiKey signing
   path, using the new in-slot key.
4. Replace the cert-only beacon in slot 9d with the freshly-issued cert.
5. Optionally retire the file-based `dev-ca.key.pem` (shred the disk
   key) once a couple of leaf rotations under the new HSM-resident Dev
   CA have validated end-to-end.

Repeat for slot 82 (Prod CA). The leaf signing key in slot 83 follows
the same pattern at the next annual rotation.

The retired slots 82–95 layout also lets us keep previous-generation
signing keys on-device for verifying older artifacts after a rotation
— see `~/ykcs11-build/SLOT_MAPPING.md` for the operator-local mapping
documentation.

## Known Pitfalls and Workarounds

Five real ecosystem traps hit during the rpi5-iot-gw rollout. Each costs
hours the first time. Documented here so the next operator can skip
straight to the fix.

### 1. Leaf cert needs both `codeSigning` AND `emailProtection` EKUs

**Symptom**: `make bundle-...-fit` fails in `do_bundle` with:

```
signature verification failed: Verify error: unsuitable certificate purpose
```

…even though the leaf cert clearly carries
`extendedKeyUsage = critical, codeSigning` and `system.conf` declares
`check-purpose=codesign` in the device-side `[keyring]` section.

**Why**: `rauc bundle` post-signs the bundle and immediately re-verifies
it via OpenSSL's `CMS_verify()`. OpenSSL hardcodes the
`X509_PURPOSE_SMIME_SIGN` purpose check at that call site —
**`check-purpose=codesign` from `system.conf` is a runtime/install-time
setting and is not consulted at bundle-creation time**. The RAUC
maintainers acknowledge this trap (rauc issue #1124) and decline to fix
it because their own customer projects use a separate PKI for RAUC.

**Fix**: add `emailProtection` to the leaf's EKU alongside `codeSigning`.
This expands the leaf's nominal scope slightly (it would also be valid
for S/MIME signing — practically a non-issue for a code-signing leaf
not deployed to email infrastructure) but makes it pass OpenSSL's
hardcoded smimesign check:

```ini
# in openssl-dev-leaf.cnf [v3_leaf_signing] block
extendedKeyUsage = critical, codeSigning, emailProtection
```

Re-sign the leaf with the Dev CA, no other change needed. Root and Dev
CA do NOT need `emailProtection` — only the leaf participates in CMS
signing.

### 2. `openssl x509 -req -CAkey <pkcs11-uri>` does not work — use `openssl ca`

**Symptom**: signing an intermediate's CSR with the YubiKey-resident
Root via `openssl x509 -req -CAkey "pkcs11:..."` fails with:

```
do_sigver_init: operation not supported for this keytype
```

…after entering only one PIN prompt (instead of the expected two).

**Why**: pkcs11-provider 0.3 + OpenSSL 3.0.13's `-CAkey URI` path uses
a different internal key-load codepath than the working `-key URI`
path. The signer-init dispatcher rejects the operation before reaching
PKCS#11 `C_Login`.

**Fix**: use `openssl ca` with a config that specifies the
PKCS#11 URI in `[ca].private_key`. This goes through the EVP_PKEY load
path that pkcs11-provider supports, and gives you a proper issuance
audit trail (`index.txt` + `serial` + `newcerts/`) as a bonus.

### 3. pkcs11-provider load order matters: `default` first

**Symptom**: `openssl ca` with mixed file-based and HSM-based keys
fails on CSR self-signature verification with:

```
p11prov_sig_operate_init: The specified key handle is not valid
```

**Why**: with `-provider pkcs11 -provider default`, pkcs11-provider
grabs every signature operation including the CSR self-signature check
on the **file-based** CSR pubkey — and immediately errors because no
PKCS#11 handle matches that key.

**Fix**: reverse the load order: `-provider default -provider pkcs11`.
The default provider handles operations on file-based keys, and
pkcs11-provider only fires when the URI is explicitly PKCS#11.

### 4. Why `RAUC_CERT_FILE` is the leaf only, and intermediates ride in `BUNDLE_ARGS`

**Background**: the wiring examples above set `RAUC_CERT_FILE` to the
leaf cert alone, and pass intermediates separately via
`BUNDLE_ARGS="--intermediate=..."`. The naïve operator instinct is to
concatenate leaf + Dev CA into a "chain" PEM and point
`RAUC_CERT_FILE` at it — that path silently breaks.

**Symptom if you try the chain-PEM approach**: bundle creation
succeeds, but the post-sign verification inside `rauc bundle` fails:

```
signature verification failed: Verify error: unable to get local issuer certificate
```

**Why it breaks**: `RAUC_CERT_FILE` is passed verbatim to
`rauc bundle --cert=`, which expects a **single** leaf certificate. If
the file contains multiple certs, `rauc` reads only the first (the
leaf) and the intermediate never makes it into the CMS signature. The
build-time verifier then can't bridge `leaf → Root` and errors out.

**Resolution** (already baked into the wiring examples — restated here
so the trap is documented next to its symptom):

```yaml
RAUC_CERT_FILE = "${RAUC_CA_DIR}/issued/dev/iotgw-rauc-dev-signer-2026.cert.pem"
BUNDLE_ARGS    = "--intermediate=${RAUC_CA_DIR}/dev-ca/dev-ca.cert.pem"
```

This is a `meta-rauc/classes-recipe/bundle.bbclass` ergonomics gap —
there's no first-class `RAUC_INTERMEDIATE_FILES` variable. `BUNDLE_ARGS`
is the escape hatch.

### 5. Why `RAUC_KEYRING_FILE` is explicitly set to a Root in the wiring

**Symptom**: bundle build fails with:

```
signature verification failed: Verify error: unable to get issuer certificate
```

(note: "issuer", not "local issuer" — this is the *next-up* problem
after problems 1, 3, 4 are solved.)

**Background**: the wiring examples above explicitly set
`RAUC_KEYRING_FILE` to a Root cert path. Operators new to the chain
might omit it, expecting some sensible default — that path silently
breaks if the default doesn't already match the new Root.

**Why the default doesn't work**:
`meta-iot-gateway/conf/distro/include/iotgw-common.inc` declares
`RAUC_KEYRING_FILE ?= "dev-cert.pem"`. meta-rauc resolves this filename
relative to `RAUC_CERT_FILE`'s directory and uses it as the trust
anchor for the post-sign verification `rauc bundle` runs internally.
The legacy `dev-cert.pem` is a self-signed cert outside the new chain
— it cannot complete `leaf → Dev CA → Root` validation.

**Resolution** (already baked into the wiring examples):

```yaml
RAUC_KEYRING_FILE = "${RAUC_CA_DIR}/root-ca/root-ca-primary.crt"
```

This is **build-time only** — the device-side keyring is wired
independently via `IOTGW_RAUC_KEYRING_CERTS` (which lists the trust
anchors installed into `/etc/rauc/keyring.d/`). The two settings serve
different audiences (build host vs device) and intentionally don't
share a variable.

## References

- `kas/local.yml.example` — committed convention for the build-time
  variables consumed by `rauc-conf-iotgw`.
- `meta-iot-gateway/recipes-ota/rauc/rauc-conf-iotgw_1.0.bb` — recipe
  that renders `/etc/rauc/system.conf` and installs the keyring
  directory.
- `meta-iot-gateway/recipes-ota/rauc/files/iotgw-system.conf` —
  `system.conf` template with the four token placeholders the recipe
  substitutes (compatible string, TLS key, keyring locator, check-purpose,
  allowed-signer-cns).
- `docs/RAUC_UPDATE.md` — RAUC bundle install lifecycle on the device
  (RAUC slot/boot semantics, install hooks, A/B rollback). Trust-anchor
  policy described here is independent of the install mechanics
  documented there.
- `docs/SECURITY.md` — overall security posture; this PKI is one
  component of it.
