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
| `make desktop` | `iot-gw-image-desktop` (lab image, always with the DX-M1 stack) |
| `make bundle IMAGE=desktop` | desktop full bundle |
| `make bundle IMAGE=dev` | dev full bundle (rootfs + signed FIT boot assets) |
| `make bundle IMAGE=prod` | prod full bundle (rootfs + signed FIT boot assets) |

Initial setup:

```bash
cp kas/local.yml.example kas/local.yml
# edit kas/local.yml for local settings (keys, WiFi, feature flags)
```

Feature-gated build examples:

```bash
IOTGW_ENABLE_OTBR=1 make dev
```

Kernel feature sets (`IOTGW_KERNEL_FEATURES`) are not forwarded from the
environment; set them in `kas/local.yml` (see the commented example in
`kas/local.yml.example`).

RAUC bundles are **encrypted (`crypt`) by default**; `verity` is an explicit
opt-out. A bundle build fails rather than falling back if no usable recipient
certificate is configured, and a freshly flashed device cannot install a crypt
bundle until its decryption identity has been provisioned. Confirm what an
artifact actually is with `rauc info --no-verify <bundle>.raucb`.

For OTA feature-gate combinations (crypt default vs verity opt-out, file-key vs
TPM vs PKCS#11 streaming) and the three locations device key material lives in,
see [OTA Updates](OTA_UPDATE.md), §Feature-Gating Profiles.

Release version override example:

```bash
IOTGW_VERSION_MAJOR=0 \
IOTGW_VERSION_MINOR=4 \
IOTGW_VERSION_PATCH=0 \
IOTGW_BUILD_ID=20260509 \
make bundle IMAGE=prod
```

When Makefile abstraction is not enough:

```bash
. scripts/env.sh && kas shell kas/local.yml -c 'bitbake-layers show-layers'
. scripts/env.sh && kas shell kas/local.yml -c 'bitbake-getvar -r virtual/kernel IOTGW_KERNEL_FEATURES'
```

A bare `kas` call without `scripts/env.sh` clones the layer stack into the
repo root (AGENTS.md).

## 2) Flash Media

Full write (recommended, especially for previously used cards):

```bash
zstdcat build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.zst \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Fast path — sparse-aware copy, then drop any stale U-Boot env file:

```bash
sudo bmaptool copy \
  build/tmp/deploy/images/raspberrypi5/iot-gw-image-dev-raspberrypi5.rootfs.wic.zst \
  /dev/sdX
sudo mount /dev/sdX2 /mnt && sudo rm -f /mnt/uboot.env && sudo umount /mnt
```

The U-Boot environment lives as a file (`uboot.env`) on the vfat `ubootenv`
partition (p2). `bmaptool` writes only mapped blocks, so a reused card can
keep its previous env file — including exhausted RAUC boot-attempt counters,
which prevents first boot. Deleting the file restores the built-in default
environment on next boot. Do **not** zero the partition itself: the vfat
filesystem and its `ubootenv` label must survive, or the `/uboot-env` mount
(`LABEL=ubootenv` in fstab) times out and boot drops to emergency mode.
Recovery from an accidentally zeroed p2: `mkfs.vfat -n ubootenv /dev/sdX2`.

## 3) Network Configuration

Network configuration is fixed at build time and changed through a new image.
`iotgw-network-units` ships the topology: `br0` bridge with `eth0` as port
(DHCP) and `wlan0` Wi-Fi driven by `wpa_supplicant@wlan0` + systemd-resolved.
Wi-Fi networks, credentials and per-SSID static addressing come from the
`IOTGW_WIFI_*` settings in `kas/local.yml` (`IOTGW_WIFI_NETWORKS`; the syntax is
documented in the recipe and in `kas/local.yml.example`). An edit under `/etc`
on the device is discarded at the next reboot.

Runtime network diagnostics:

```bash
networkctl status                 # per-link state, addresses
networkctl reload                 # re-read /etc/systemd/network
resolvectl status                 # DNS servers / resolved state
wpa_cli -i wlan0 scan && wpa_cli -i wlan0 scan_results
systemctl status systemd-networkd wpa_supplicant@wlan0
```

Wi-Fi control-plane checks:

```bash
wpa_cli -p /run/wpa_supplicant -i wlan0 ping
wpa_cli -p /run/wpa_supplicant -i wlan0 status
iw dev wlan0 link
```

Expected healthy output includes `PONG`, `wpa_state=COMPLETED`, the associated
SSID, and the assigned `wlan0` address. If `iw dev wlan0 link` shows an
association but `wpa_cli` times out, inspect the `wpa_supplicant@wlan0`
hardening drop-in:

```bash
systemctl --no-pager cat wpa_supplicant@wlan0.service
```

The `wpa_supplicant@wlan0` profile must keep `PrivateTmp=false`.
`wpa_cli` creates its reply socket under `/tmp`; a private `/tmp` lets
`wpa_supplicant` receive commands through `/run/wpa_supplicant/wlan0` but
prevents it from sending replies to the client. From an administrator shell
(`sysadm_t`, see Section 10), the namespace view can be checked with:

```bash
pid=$(pidof wpa_supplicant)
ls -l /proc/1/ns/mnt /proc/$$/ns/mnt /proc/$pid/ns/mnt
nsenter -t "$pid" -m ls -ld /tmp
```

## 4) Dev SSH Keys (Dev and Desktop Images)

Use `iotgw-dev-ssh-keys` via host file paths:

```conf
IOTGW_DEV_ROOT_AUTH_KEYS_FILE = "/home/me/keys/root_authorized_keys"
IOTGW_DEV_DEVEL_AUTH_KEYS_FILE = "/home/me/keys/devel_authorized_keys"
```

For **prod** images, see Section 5: `iotgw-dev-ssh-keys` is dev/desktop-only,
and prod ships no authorized key and no account with a password.

SSH is key-only on every tier (`sshd_config.d/99-iotgw.conf`: password and
keyboard-interactive authentication off). The account password hashes set in
`kas/local.yml` serve the serial console, `sudo` and `newrole` on dev and
desktop; they never work over the network.

## 5) Prod Administration And Recovery

### Posture (by design)

A prod image is a closed appliance with **one** login, the OTA operator, and
**no administrator**.

- No account has a password. Root's shadow entry is `*`
  (`iot-gw-image-prod.bb`; the build fails if it is anything else), there is
  no `devel` account, and the operator account has `*` too. The serial
  console, `newrole` and `sudo` therefore refuse everyone: `*` matches no
  password in `pam_unix`. `IOTGW_ROOT_PASSWORD_HASH` in `kas/local.yml` does
  not reach prod (the recipe's `=` overrides it).
- Root cannot log in over the network (`PermitRootLogin no`,
  `AllowUsers iotgw-ops` in `10-iotgw-prod-auth.conf`), and the build refuses
  a prod rootfs that carries `/root/.ssh/authorized_keys`.
- `iotgw-ops` is the operator: key-only (the key file is named by
  `IOTGW_PROD_OPS_AUTH_KEYS_FILE` in `kas/local.yml`; the prod build fails
  without it), SELinux `staff_t`, no elevation. It may copy a bundle to
  `/data/ota-tmp`, run `rauc install`, `rauc status` and the mark commands,
  and read the journal; nothing else on the device is writable to it. The key
  is read from `/etc/ssh/authorized_keys.d/iotgw-ops` in the image, so an
  update rotates or revokes it.
- `sshd` is bound to IPv4 port 22 (`05-iotgw-listen.conf`) with password and
  keyboard-interactive authentication off and all forwarding disabled; the
  firewall admits the port from any IPv4 source.

### What administers a prod device

| Mechanism | What it does | Depends on |
|---|---|---|
| OTA, automatic (`ota-updater.timer`) — **dev only** | Prod ships no updater (`packagegroup-iot-gw-prod` keeps periodic polling out by decision); on dev, 2 min after boot and then hourly, `ota-update-check` fetches the fleet manifest over mTLS and runs `rauc install <bundle-url>` when the manifest version is newer than the booted slot. RAUC verifies the bundle signature; the bundle hooks record the new slot as "on trial". | `/etc/ota/updater.conf` and a valid device certificate (`ota-certs-provision`: from `/boot/iotgw/ota/` on the card at first boot, then kept in `/data/ota/certs`); a reachable OTA server; a healthy `/data` (installs are refused on a degraded boot). |
| A/B fallback (U-Boot boot counters) | Each slot has `BOOT_A_LEFT`/`BOOT_B_LEFT` attempts (3 by default) in the U-Boot environment on p2. A slot on trial is marked good by `rauc-mark-good.service` on its first healthy boot (`iotgw-mark-good-gate`: a degraded boot of a slot still on trial is *not* marked good); when the attempts are exhausted U-Boot boots the other slot. Both slots exhausted: U-Boot halts. | The `/uboot-env` partition (p2) and the previous slot still holding a bootable, signed image. |
| Physical reflash | [Section 2](#2-flash-media): write the `.wic.zst` to the card. Writes every partition, including `/data`, so the device comes back provisioned from scratch (OTA certificate from the card's `/boot/iotgw/ota/` again). | Physical access. |

| OTA operator over SSH (`iotgw-ops`) | `scp bundle.raucb iotgw-ops@<device>:/data/ota-tmp/`, then `ssh iotgw-ops@<device> rauc install /data/ota-tmp/bundle.raucb`; `rauc status`, `rauc status mark-good` / `mark-bad`, `journalctl` for diagnosis. The install itself runs in the RAUC daemon as on every tier. | The operator's key (built in), network reachability, a healthy `/data`. |

What is **not** a mechanism on prod, because each needs an administrator shell: `iotgw-rauc-install` (its `systemd-run` dispatch), `systemctl`, the serial console, and the "key for this boot" procedure below (dev and desktop only).

### Operational limits — know these before flashing prod

- A broken automatic OTA path (expired or missing device certificate —
  `ota-updater.service` has `ConditionPathExists=/etc/ota/device.crt` — or an
  unreachable server) is recoverable by the operator over SSH with a staged
  bundle, as long as the device is reachable and `/data` is healthy. A `/data`
  that fails to mount or fsck (degraded boot) refuses installs and seeds the
  operator's home from the image, so the key still works but nothing can be
  staged: **reflash is the only path** there.
- Operator rollback: `rauc status mark-active <other slot>` from the operator
  account switches the next boot to the previous slot while it still holds a
  bootable, signed image; the install after that overwrites it.
- Diagnostics: `journalctl` and `rauc status` over SSH; offline, pull the card
  and read `/data` (ext4: audit log under `/data/log/audit`, RAUC events in
  `/data/rauc-events.log`, the pre-init log is not persisted).
- A degraded boot is not visible from the outside. `edge-healthd` reports
  through the observability stack when that is enabled; otherwise the
  device simply stops taking updates.

### Dev and desktop images

Root has a password (`IOTGW_ROOT_PASSWORD_HASH` in `kas/local.yml`; the
layer default is `*`) for the serial console and `newrole`; `devel` has
`sudo` and its own hash. Both accounts get keys from `iotgw-dev-ssh-keys`.
A key added on the device under `/home/devel/.ssh/authorized_keys` persists
(`/home` is bound from `/data/home`); one under `/root/.ssh/authorized_keys`
is gone at the next reboot (`/root` is a tmpfs overlay), so root keys are
delivered through the build. The runbook below is for a dev or desktop
device whose baked keys are wrong.

### Runbook (dev/desktop): a key for this boot, from the serial console

1. **Verify the current sshd policy**:

   ```bash
   sshd -T -f /etc/ssh/sshd_config_readonly 2>/dev/null | grep -iE 'permitrootlogin|passwordauthentication|pubkeyauthentication|authorizedkeysfile'
   ls -l /etc/ssh/sshd_config.d/ 2>/dev/null
   ```

   Expected: `permitrootlogin prohibit-password`, `passwordauthentication no`,
   `pubkeyauthentication yes`, `authorizedkeysfile .ssh/authorized_keys`.

2. **Install the key** (inline paste, or a file from a USB stick /
   kermit-over-serial); for `devel`, use `/home/devel/.ssh` and `devel:devel`
   ownership, and it persists:

   ```bash
   install -d -m 0700 -o root -g root /root/.ssh
   cat >> /root/.ssh/authorized_keys <<'EOF'
   ssh-ed25519 AAAA... operator@workstation
   EOF
   chmod 0600 /root/.ssh/authorized_keys
   ```

   The file must be `0600` and owned by the account or sshd refuses it
   (`StrictModes yes` default). No sshd reload is needed: `authorized_keys`
   is read on every connection.

3. **Verify login from your workstation**:

   ```bash
   ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/<operator_key> root@<device>
   ```

### Cautions

- **Do not relax sshd hardening.** `PasswordAuthentication yes` or
  `PermitRootLogin yes` re-creates the surface the images are designed
  to avoid, and an edit under `/etc` is discarded at the next reboot anyway:
  `/etc` is the shipped configuration plus a tmpfs upper layer. Policy
  changes ship in the image.
- **OTA and reboot behaviour**: `/etc` and `/root` start from the slot's
  image on every boot, so nothing written there survives a reboot, a RAUC
  install or a slot switch. `/home` is bound from `/data/home` and does
  survive all three, shared by both slots.
- **The `devel` user (dev and desktop images)** has its home on
  `/data/home/devel`. On the first boot of a `/data` without it, the pre-init
  copies the image's `/home/devel` (including the
  `iotgw-dev-ssh-keys` `authorized_keys`) there once. Later images do not
  refresh that copy: a changed developer key reaches an existing device only
  by editing `/home/devel/.ssh/authorized_keys` on it, or by deleting
  `/data/home/devel` so the next boot copies it again.

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

## 7) Check The Boot Assembly

Every image boots through `iotgw-preinit`, which mounts `/data` and assembles
`/etc`, `/root` and `/home` before systemd. Its log and the degraded marker
are in `/run/iotgw`:

```bash
cat /run/iotgw/preinit.log
cat /run/iotgw/degraded 2>/dev/null || echo "not degraded"
findmnt -no SOURCE,FSTYPE /proc/1/root/home       # /dev/...p5[/home] ext4
cat /uboot-env/iotgw-trial-slot 2>/dev/null       # slot on trial since its install, if any
```

A degraded boot (no usable `/data`) keeps the shipped configuration (dev and
desktop: baked keys and the console password still work; prod: still no
login) and refuses OTA installs. It is marked good as
usual, except on a slot still on trial since its install
(`/uboot-env/iotgw-trial-slot`), which falls back to the previous slot.

## 8) Service Health Checks

```bash
systemctl status edge-healthd
journalctl -u edge-healthd --no-pager -n 100
```

## 9) Persistent Remote Session Pattern

For repeated gateway operations, keep a tmux session on the target:

```bash
ssh -t root@<device> 'tmux new-session -A -s gateway'
```

`-A` attaches when the session exists and creates it otherwise. The server
socket is tmux's default, `/tmp/tmux-<uid>/default`. `/tmp` is one tmpfs for
the whole system, so the session outlives SSH reconnects; it does not outlive
a reboot.

A tmux server keeps the SELinux domain of the shell that started it, and so
does every pane. A server started from a plain SSH login runs in that login's
domain (`staff_t`, see Section 10); start it from an elevated shell when the
panes are meant for administration. A client cannot attach to a server in
another domain: give the admin session its own name
(`tmux new-session -A -s gateway-admin`).

## 10) SSH Sessions, Mounts And SELinux Domains

`sshd` runs as one daemon (`sshd.service`, `sshd -D`) without a mount
namespace sandbox. An SSH shell sees the same mounts, `/etc`, `/tmp` and
`/run` as PID1 and the system services, so `findmnt /etc` or
`/proc/self/mountinfo` from SSH is the real answer and needs no `nsenter`.
What `/etc` is and what survives a reboot:
[Persistent State Architecture](PERSISTENT_STATE.md).

What differs between login paths is the SELinux domain. PAM's `pam_selinux`
picks it at login from `/etc/selinux/<policy>/contexts`:

| Login | Domain | Can administer the system |
|---|---|---|
| Serial console, `root` | `sysadm_t` | yes |
| SSH, `root` (key only) | `staff_t` | no: elevate first |
| SSH, `devel` (dev, desktop) | `staff_t` | no: elevate with `sudo` |
| SSH, `iotgw-ops` (prod) | `staff_t` | no: stages and installs bundles only |

The console mapping means physical access to the UART is administrator
access. SSH sessions start with less and elevate explicitly:

```bash
id -Z                      # current domain
sudo -i                    # members of the sudo group: lands in sysadm_r:sysadm_t
newrole -r sysadm_r        # any account whose SELinux user may hold sysadm_r; asks for the password
```

`sudo` takes the role and type from `/etc/sudoers.d/10-iotgw-admin-selinux`.
`newrole` authenticates through PAM and asks for the account's own password,
so it works only for an account that has one. Prod has no path to
`sysadm_t`: no account is in the `sudo` group, no account has a password, and
root cannot log in at all (no password, `PermitRootLogin no`). Its one login is
the OTA operator, `iotgw-ops`, with the key given at build time: it copies a
bundle to `/data/ota-tmp`, runs `rauc install`, `rauc status` and the mark
commands, and reads the journal. Everything else on prod is changed through
OTA images or a reflash.

Under enforcing, a `Permission denied` for root in an SSH shell is usually
the `staff_t` domain, not a file mode or a mount. Check the domain first, then
read the denial from an administrator shell: `staff_t` cannot read the audit
log, and `ausearch` there prints `<no matches>` whatever the log holds.

```bash
id -Z                      # in the SSH shell
newrole -r sysadm_r        # then, as sysadm_t:
ausearch -m avc -ts recent
```

Containers are rootless and belong to the `iotgw-ctr` account (its user
manager, Quadlets under `/etc/containers/systemd/users/968/`, store under its
home on `/data/home`; see `docs/CONTAINERS.md`). No container store is
administered as `sysadm_t`: there is no rootful engine, and `podman` started
from an administrator shell would use a volatile store of its own.

## 11) Persistent State

`/var` is volatile; only an explicit set of paths persists on `/data`. The full
layout — what is volatile, what persists, and what survives A/B updates — is in
[Persistent State Architecture](PERSISTENT_STATE.md), together with the
checks of the layout from PID1's view and the `ota-smoke` target check that
covers it.

## Related

- [RAUC Update Runbook](RAUC_UPDATE.md) - install semantics and troubleshooting
- [Persistent State Architecture](PERSISTENT_STATE.md) - what persists, the bind list, the pre-init
- [Security Hardening](SECURITY.md) - hardening baseline
- [Observability Stack](OBSERVABILITY.md) - stack behavior
- [FIT Boot and Signing Guide](FIT_BOOT_SIGNING.md) - FIT boot/signing path
