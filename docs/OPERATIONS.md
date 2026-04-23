# Operations Guide

This runbook is the practical day-to-day playbook for operating this project on:

- host build machine
- gateway target devices

Audience: operators, integrators, and maintainers.

## 1) Build And Package

| Command | Output |
|---------|--------|
| `make dev` | `iot-gw-image-dev` |
| `make prod` | `iot-gw-image-prod` |
| `make base` | `iot-gw-image-base` |
| `make desktop` | `iot-gw-image-desktop` |
| `make bundle-dev-full` | dev full bundle (rootfs + boot assets) |
| `make bundle-prod-full` | prod full bundle (rootfs + boot assets) |

Initial setup:

```bash
cp kas/local.yml.example kas/local.yml
# edit kas/local.yml for local settings (keys, WiFi, feature flags)
```

Feature-gated build examples:

```bash
IOTGW_ENABLE_OTBR=1 make dev
IOTGW_ENABLE_OBSERVABILITY=1 make dev
IOTGW_KERNEL_FEATURES="igw_containers igw_networking_iot igw_security_prod" make prod
```

For OTA feature-gate combinations (verity vs crypt bundle, file-key vs TPM vs
PKCS#11 streaming), see the matrix in [OTA Updates](OTA_UPDATE.md#feature-gating-matrix-verity--tpm--pkcs11--encrypted-bundles).

Release version override example:

```bash
IOTGW_VERSION_MAJOR=0 \
IOTGW_VERSION_MINOR=3 \
IOTGW_VERSION_PATCH=0 \
IOTGW_BUILD_ID=20260408 \
make bundle-prod-full
```

When Makefile abstraction is not enough:

```bash
kas build kas/local.yml --target iot-gw-image-dev
kas shell kas/local.yml
bitbake-layers show-layers
bitbake -e virtual/kernel | rg "^IOTGW_KERNEL_FEATURES="
```

## 2) Flash Media

```bash
sudo bmaptool copy \
  build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.bz2 \
  /dev/sdX
```

## 3) Provision Network Before First Boot

Provisioning input source is `/data/iotgw`:

- `/data/iotgw/nm/*.nmconnection`
- `/data/iotgw/nm-conf/*.conf`
- `/data/iotgw/observability.env` (optional)

Default layout note: data partition is `mmcblk0p5` (`/dev/sdX5` on removable media).

Pre-boot media prep:

```bash
sudo mount /dev/sdX5 /mnt
sudo mkdir -p /mnt/iotgw/{nm,nm-conf}
sudo cp HomeWiFi.nmconnection /mnt/iotgw/nm/
sudo chmod 600 /mnt/iotgw/nm/HomeWiFi.nmconnection
sudo umount /mnt
```

Runtime network management:

```bash
nmcli connection show
nmcli device wifi list
nmcli connection up <name>
nmcli connection modify <name> ipv4.method auto
nmtui
```

## 4) Dev SSH Keys (Dev Image Only)

Use `iotgw-dev-ssh-keys` via host file paths:

```conf
IOTGW_DEV_ROOT_AUTH_KEYS_FILE = "/home/me/keys/root_authorized_keys"
IOTGW_DEV_DEVEL_AUTH_KEYS_FILE = "/home/me/keys/devel_authorized_keys"
```

## 5) Install OTA And Verify

```bash
iotgw-rauc-install <bundle>.raucb
reboot
rauc status --detailed
journalctl -u rauc --no-pager -n 200
```

Streaming OTA:

```bash
iotgw-rauc-install https://<ota-host>:8443/bundles/<bundle>.raucb
```

## 6) Validate Overlay Reconciliation

```bash
ls -l /data/iotgw/overlay-reconcile/
cat /data/iotgw/overlay-reconcile/txn.json
cat /data/iotgw/overlay-reconcile/state.tsv
journalctl -u rauc.service --no-pager | rg "overlay-reconcile|bundle-hook"
```

Architecture and policy details:
- [Overlay Reconciliation Architecture](OVERLAY_RECONCILIATION.md)

## 7) Service Health Checks

```bash
systemctl status mosquitto telegraf influxdb
journalctl -u telegraf --no-pager -n 100
```

## 8) Persistent Remote Session Pattern

For repeated gateway operations, use persistent tmux on target:

```bash
ssh iotgw "mkdir -p /data/tmux && \
  tmux -S /data/tmux/gateway.sock has-session -t gateway 2>/dev/null || \
  tmux -S /data/tmux/gateway.sock new-session -d -s gateway; \
  tmux -S /data/tmux/gateway.sock attach -t gateway"
```

This keeps long-running OTA/debug sessions stable across SSH reconnects.

## Related

- [RAUC Update Runbook](RAUC_UPDATE.md) - install semantics and troubleshooting
- [Overlay Reconciliation Architecture](OVERLAY_RECONCILIATION.md) - policy architecture and tradeoffs
- [Security Hardening](SECURITY.md) - hardening baseline
- [Observability Stack](OBSERVABILITY.md) - stack behavior and credential flow
- [FIT Boot and Signing Guide](FIT_BOOT_SIGNING.md) - FIT boot/signing path
