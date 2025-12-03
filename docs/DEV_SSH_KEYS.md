# Developer SSH Keys (dev image only)

For developer convenience, SSH authorized_keys can be baked into the development image (`iot-gw-image-dev`) via a dedicated package. Production images do not include developer keys.

## How it works

- Package: `iotgw-dev-ssh-keys`
- Included only in `iot-gw-image-dev`
- Installs optional files to:
  - `/root/.ssh/authorized_keys`
  - `/home/devel/.ssh/authorized_keys`

Keys are provided from the build host via variables that point to files containing the desired key list.

## Configure keys (kas/local.yml or local.conf)

```
# Absolute paths on the build host
IOTGW_DEV_ROOT_AUTH_KEYS_FILE = "/home/me/keys/root_authorized_keys"
IOTGW_DEV_DEVEL_AUTH_KEYS_FILE = "/home/me/keys/devel_authorized_keys"
```

Both variables are optional. If unset or the files do not exist, nothing is installed for that user.

## Notes

- Ownership and permissions:
  - Directories are created with `0700`; files with `0600`.
  - `/home/devel` ownership is normalized by the image class to UID/GID 1000.
- Security: This mechanism is not included in production images.
- First-boot provisioning: SSH keys are intentionally not handled by `iotgw-provision` to keep a single responsibility (network only).

