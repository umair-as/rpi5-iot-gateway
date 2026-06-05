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
IOTGW_KERNEL_FEATURES="igw_containers igw_networking_iot igw_security_prod" make prod
```

For OTA feature-gate combinations (verity vs crypt bundle, file-key vs TPM vs
PKCS#11 streaming), see the matrix in [OTA Updates](OTA_UPDATE.md#feature-gating-matrix-verity--tpm--pkcs11--encrypted-bundles).

Release version override example:

```bash
IOTGW_VERSION_MAJOR=0 \
IOTGW_VERSION_MINOR=4 \
IOTGW_VERSION_PATCH=0 \
IOTGW_BUILD_ID=20260509 \
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

For **prod** images, see Section 5 — `iotgw-dev-ssh-keys` is dev/desktop-only;
prod ships without any baked authorized_keys.

## 5) Prod SSH Recovery Path

### Expected posture (by design)

A freshly-flashed prod image has TCP port 22 open but **no usable login path**:

- `iotgw-dev-ssh-keys` is installed only in `iot-gw-image-dev` and
  `iot-gw-image-desktop`. Prod ships with empty `/root/.ssh/authorized_keys`.
- `iotgw-sshd-hardening`'s `99-iotgw.conf` sets
  `PermitRootLogin prohibit-password` — root may only log in via key, never
  via password.
- Root password is empty/locked. No password login is possible.

The result is "defense by absence": port 22 is reachable but auth-deadlocked
unless an operator has provisioned a key. **An open port 22 on a prod
device does not imply access is configured.** This is the intended shipping
state.

### Recovery options (in order of preference)

1. **Serial console / local operator session.** The supported recovery
   path. You get a root shell directly, no SSH involved. Use this whenever
   physical/UART access is available.
2. **OTA bundle install with a recovery image.** If the device is fielded
   and you control the OTA channel, ship a bundle whose rootfs has
   `iotgw-dev-ssh-keys` (or your operator authorized_keys) installed.
   Standard `iotgw-rauc-install` then reboot.
3. **Add an authorized key via the `/data` overlay upper.** Possible from
   any context that can write to `/data/overlays/root/upper/.ssh/` — most
   commonly a serial session, occasionally a recovery initramfs or
   SD-card mount on a host. Do **not** edit the immutable rootfs; do
   **not** edit a slot's mounted `/root` directly during OTA install.
   The overlay upper is the only correct persistent surface.

Forget about adding keys "by SSH" without a key — that's the deadlock
this section exists to recover from.

### Runbook (from a serial-console root shell)

The overlay layout (from `overlayfs-setup.sh`) is:

```
/root          ← overlay mount (lower = immutable slot rootfs, upper = persistent)
/data/overlays/root/upper/    ← persistent upper layer (this survives reboots and OTAs)
```

Files placed under `/data/overlays/root/upper/.ssh/` will appear at
`/root/.ssh/` via the overlay.

1. **Verify the current sshd policy** (so you know what auth path will
   work once a key is installed):

   ```bash
   sshd -T 2>/dev/null | grep -iE 'permitrootlogin|passwordauthentication|pubkeyauthentication|authorizedkeysfile'
   ls -l /etc/ssh/sshd_config.d/ 2>/dev/null
   cat /etc/ssh/sshd_config.d/99-iotgw.conf 2>/dev/null
   ```

   Expected on a stock prod image: `permitrootlogin prohibit-password`,
   `pubkeyauthentication yes`, `authorizedkeysfile .ssh/authorized_keys`.

2. **Stage the persistent root SSH directory under the overlay upper**:

   ```bash
   install -d -m 0700 -o root -g root /data/overlays/root/upper/.ssh
   ```

   This creates the persistent directory. It will be visible at
   `/root/.ssh/` immediately via the running overlay.

3. **Install the operator authorized_keys**. Paste your public key
   inline, or transfer the file via a USB stick / kermit-over-serial /
   whatever the local context allows:

   ```bash
   # Example: inline paste
   cat > /data/overlays/root/upper/.ssh/authorized_keys <<'EOF'
   ssh-ed25519 AAAA... operator@workstation
   EOF
   chmod 0600 /data/overlays/root/upper/.ssh/authorized_keys
   chown root:root /data/overlays/root/upper/.ssh/authorized_keys
   ```

   The file must be `0600` and owned by `root:root` or sshd will refuse
   to use it (sshd's `StrictModes yes` default).

4. **Verify the overlay sees the new file**:

   ```bash
   ls -la /root/.ssh/
   # Expect: drwx------ 2 root root ... .
   # Expect: -rw------- 1 root root ... authorized_keys
   ```

5. **No sshd reload needed.** `authorized_keys` is read on every
   incoming connection — the next `ssh` attempt will see the new key
   without any service action. (sshd reload would only be needed if
   you'd edited `sshd_config` or a `sshd_config.d/*.conf` drop-in.)

6. **Verify login from your workstation**:

   ```bash
   # On the workstation:
   ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/<operator_key> root@<device>
   ```

7. **Cleanup / removal** (once the recovery work is done and the
   intended access pattern is restored, e.g. you've delivered a new
   OTA bundle):

   ```bash
   # From the recovered session (or serial):
   rm -f /data/overlays/root/upper/.ssh/authorized_keys
   rmdir /data/overlays/root/upper/.ssh 2>/dev/null || true
   ```

   The overlay upper is the source of truth — once these files are
   removed, the overlay falls through to the (empty) lower-layer
   `/root/.ssh/`, and the device is back to the "no SSH login" posture.

### Cautions

- **Do not relax sshd hardening permanently.** Adding
  `PasswordAuthentication yes` or `PermitRootLogin yes` to a persistent
  drop-in re-creates the very surface area the prod image is designed
  to avoid. The key-in-overlay path above does not require any sshd
  policy change.
- **Avoid editing the main `sshd_config`** when a drop-in or a
  persistent overlay file is enough. The main file is part of the
  immutable rootfs; modifications would have to go through `/etc`'s
  overlay (which `managed-paths.conf` will re-enforce on the next OTA).
  An `sshd_config.d/*.conf` drop-in in the overlay upper is the
  preferred path *if* a policy change is actually required.
- **OTA overlay-reconcile behavior**: `/data/overlays/root/upper/` is
  not enumerated in `managed-paths.conf`, so the operator authorized_keys
  installed via this runbook **survives RAUC installs and slot
  switches**. If you want the key removed on the next OTA, document
  that as part of your bundle's pre/post-install hook — do not rely on
  reconcile to do it for you. Conversely, files placed in `/etc/`
  overlay are enforced against the slot's image content and may
  disappear on OTA; that's why root authorized_keys lives under
  `/root` overlay (not `/etc`).
- **The `devel` user (when present in dev images)** uses
  `/data/overlays/home/upper/devel/.ssh/authorized_keys` for the same
  pattern. Prod images don't include `devel` by default, but the same
  mechanism applies if your prod variant does.

## 6) Install OTA And Verify

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

## 7) Validate Overlay Reconciliation

```bash
ls -l /data/iotgw/overlay-reconcile/
cat /data/iotgw/overlay-reconcile/txn.json
cat /data/iotgw/overlay-reconcile/state.tsv
journalctl -u rauc.service --no-pager | rg "overlay-reconcile|bundle-hook"
```

Architecture and policy details:
- [Overlay Reconciliation Architecture](OVERLAY_RECONCILIATION.md)

## 8) Service Health Checks

```bash
systemctl status mosquitto edge-healthd
journalctl -u edge-healthd --no-pager -n 100
```

## 9) Persistent Remote Session Pattern

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
