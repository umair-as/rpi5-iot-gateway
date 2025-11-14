# RAUC Signing Keys

Private keys are **not included** in this repository for security reasons.

## For Repository Owner

Your keys are stored in `~/rauc-keys/`:
- `dev-key.pem` - Private key for signing bundles
- `dev-cert.pem` - Certificate matching the private key

These are referenced in `kas/local.yml` (git-ignored).

## For New Users

You need to generate your own RAUC signing keys before building OTA bundles.

### Generate Keys

Use the included script:

```bash
./meta-iot-gateway/scripts/generate-rauc-certs.sh
```

This will create:
- `ca.cert.pem` - CA certificate (install on devices)
- `dev-key.pem` - Private key (keep secure!)
- `dev-cert.pem` - Development certificate

### Configure Build System

Create `kas/local.yml` from the example:

```bash
cp kas/local.yml.example kas/local.yml
```

Edit the key paths:

```yaml
local_conf_header:
  rauc_keys: |
    RAUC_KEY_FILE = "/path/to/your/dev-key.pem"
    RAUC_CERT_FILE = "/path/to/your/dev-cert.pem"
```

### Build Bundles

```bash
# Build with your keys
kas build kas/local.yml --target iot-gw-bundle
```

## Security Notes

- **NEVER** commit `*-key.pem` files to git
- Keep private keys in a secure location outside the repository
- For production, use hardware security modules (HSM) or proper key management
- Each deployment should use unique keys
