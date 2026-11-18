# Persistent State Architecture

Canonical description of writable and persistent state on the gateway. This is
the source of truth; other documents summarize and link here rather than
maintaining their own state maps.

## Objective

The device boots from an A/B pair of **read-only** root filesystems that RAUC
replaces wholesale during an update. Nothing written to a root slot survives an
update. All writable state therefore has to live outside the slots, on the
shared **`/data`** partition (ext4, GPT partition `p5`, label `data`), which:

- survives reboot,
- survives a RAUC A/B slot switch and rollback (it is not a slot), and
- is re-created empty only by a full flash/reprovision.

Writable trees on the read-only rootfs are provided in one of three ways:
OverlayFS with a **tmpfs** upper layer (for `/etc` and `/root`: writable, reset
at every boot), an explicit list of `/data`-backed bind mounts (for the state
that must persist, `/home` included), or the stock OpenEmbedded volatile model
(RAM-backed, cleared each boot). No overlay layer lives on `/data`: a shipped
file under `/etc` is always the one dm-verity authenticated.

`/etc`, `/root`, `/home`, `/data` and `/etc/machine-id` are assembled by
`iotgw-preinit`, which the signed kernel command line runs as `init=` before
systemd. The binds under `/var` are systemd `.mount` units, because `/var/lib`
is itself a volatile overlay that only appears during `local-fs.target`.

`/var` is intentionally **not** an OverlayFS mount: an overlay over `/var`
would shadow the `/var/volatile` tmpfs, persist all of `/var` when only a small
subset needs to survive, and defeat the stock `volatile-binds`. Persistence is
confined to an explicit, bounded set of `/data`-backed paths.

## The `/var` model

- `/var/volatile` is a **tmpfs** (from `base-files`' fstab) and is cleared at
  every boot.
- `/var/log` and `/var/tmp` are the standard OE symlinks into `/var/volatile`
  (`/var/log -> volatile/log`, `/var/tmp -> volatile/tmp`), so logs and temp
  files are RAM-backed by default.
- The stock OE `volatile-binds` units supply writable-but-volatile `/var/lib`,
  `/var/cache`, `/var/spool`, and `/srv` on the read-only rootfs. These trees
  are writable at runtime but are **not** persistent; their rootfs content is
  visible through the copybind lower, and runtime writes are discarded at reboot.
- `/etc` and `/root` are overlays whose upper layer is a size-bounded tmpfs
  (`/run/iotgw/overlay`). Runtime writers (ldconfig, sysusers, augenrules, an
  admin's edit) work, and everything they write is gone at the next boot.
  No overlay upper lives on `/data`: a persistent upper would override the
  dm-verity–authenticated `/etc` of every later slot, and an overlay mounted
  by a systemd unit is checked as `mount_t` (see
  [SELinux trials](SELINUX_ENFORCING.md) §2.1). The pre-init deletes the
  retired `/data/overlays` and `/data/iotgw/overlay-reconcile` wherever it
  finds them.

The must-persist runtime state that would otherwise be lost is re-homed onto
`/data` (see the map below).

## Persistent-state map

Persistence classes:

- **Volatile** — RAM-backed, cleared at boot.
- **Persistent** — survives reboot on `/data`.
- **Persistent across A/B** — survives reboot *and* RAUC slot switch/rollback,
  because `/data` is outside the root slots. All `/data`-backed rows below are in
  this class; it follows that this state is **shared** between slots, not
  slot-scoped.

| State | Runtime path | Persistent backing | Mechanism | Notes |
|---|---|---|---|---|
| journald | `/var/volatile/log/journal` (via `/var/log/journal`) | `/data/log/journal` | bind mount (`var-volatile-log-journal.mount`) | `Storage=persistent`; retention below |
| auditd | `/var/volatile/log/audit` (via `/var/log/audit`) | `/data/log/audit` | bind mount (`var-volatile-log-audit.mount`) | retention below |
| pstore/crash | `/var/lib/systemd/pstore` | `/data/crash/pstore` | bind mount (`var-lib-systemd-pstore.mount`) | gated by `IOTGW_ENABLE_PSTORE_PERSIST` (default on) |
| SSH host identity | `/run/sshd-keys` | `/data/ssh` | copied each boot by `iotgw-sshd-keys.service`; `HostKey` points at `/run/sshd-keys` | generated once into `/data/ssh` (RSA 4096, ECDSA, Ed25519); without `/data`, generated for that boot only |
| TPM2 PKCS#11 token DB | `/data/tpm2_pkcs11` | `/data/tpm2_pkcs11` | `IOTGW_TPM2_PKCS11_STORE` (provider/provisioning config) | OTA mTLS device identity |
| OTA cert provisioning state | `/data/ota-certs-provision.state`, `/data/ota-certs-provision.done` | same | direct script paths | provision id/replay + completion stamp |
| OpenThread dataset | `/var/lib/thread` | `/data/lib/thread` | bind mount (`var-lib-thread.mount`) | present only with OTBR builds |
| Bluetooth adapter identity + pairings | `/var/lib/bluetooth` | `/data/lib/bluetooth` | bind mount (`var-lib-bluetooth.mount`) | gated on the `bluetooth` distro feature |
| InfluxDB 3 data | `/data/influxdb3` | `/data/influxdb3` | `INFLUXDB3_DATA_DIR` service config | only when the optional InfluxDB 3 recipe is installed |
| Container store (rootless, `iotgw-ctr`) | `/home/iotgw-ctr/.local/share/containers` | `/data/home/iotgw-ctr/...` | through the `/home` bind below | podman's per-user default; native kernel overlay driver, no `mount_program`; see [CONTAINERS.md](CONTAINERS.md) |
| machine-id | `/etc/machine-id` | `/data/machine-id` | file bind by `iotgw-preinit` (created by `iotgw-machine-id` on the first boot) | read-only bind |
| Home directories | `/home` | `/data/home` | bind by `iotgw-preinit` (`nodev,nosuid`) | each image `/home` entry absent on `/data` is copied in once |
| `/etc`, `/root` | same | none (tmpfs upper, `/run/iotgw/overlay`) | OverlayFS by `iotgw-preinit` | volatile; shipped content from the slot |

Everything else under `/var` is volatile. Notably, `/var/lib/systemd/random-seed`
and `/var/lib/systemd/timesync/clock` are not persisted; the RTC provides a clock
floor and systemd reseeds entropy. `/var/lib/systemd/rfkill` is not persisted
either: an `rfkill block` lasts until the next boot, and every boot starts with
the radios unblocked. Whether Wi-Fi is used is image configuration
(`IOTGW_WIFI_NETWORKS`), not runtime state.

## Boot and mount ordering

The journal and audit binds cannot rely on the normal `systemd-tmpfiles-setup`
pass. `systemd-journal-flush.service` is ordered *before* that pass and pulls
`/var/log/journal`, so the backing directory and mountpoint must exist earlier.
`iotgw-log-persist-prep.service` runs early (before journal flush and auditd) and
creates `/data/log/{journal,audit}` and the `/var/volatile/log/{journal,audit}`
mountpoints. The bind units then depend on that oneshot rather than on the
tmpfiles pass, which also avoids an ordering cycle with journal flush.

The bind units themselves carry no install target; they are pulled and ordered
by `Wants=`/`After=` drop-ins on their consumers — `systemd-journal-flush` for
the journal bind and `auditd` for the audit bind — referencing the mounts by
unit name. A `RequiresMountsFor=` on the symlinked `/var/log/...` path orders the
consumer but does not reliably activate the bind, so the pull is wired
explicitly.

The `/var/lib` binds (Thread, Bluetooth) target real (non-symlink) paths and
their consumers start late, so they order after `data.mount`, the stock
`/var/lib` volatile bind (`var-volatile-lib.service`), and
`systemd-tmpfiles-setup.service`, and are pulled by a `RequiresMountsFor=`
drop-in on the owning service.

Because `/var/lib` is writable only after `var-volatile-lib.service` lands,
`systemd-timesyncd` (which creates `StateDirectory=systemd/timesync`) is ordered
after that unit via a drop-in; without it, timesyncd fails
`238/STATE_DIRECTORY` early in boot and only recovers once the bind is up.

## The bind list

Everything that persists is enumerable from source: the pre-init's binds
(`meta-iot-gateway/recipes-support/iotgw-preinit/files/iotgw-preinit.sh`:
`/home`, `/etc/machine-id`) and the `.mount` units whose `What=` is under
`/data` (`grep -rn '^What=/data' meta-iot-gateway`: journal, audit, pstore,
Bluetooth, Thread). The rest of the persistent rows above are
services that read and write `/data` by path. Every bind source is a plain
directory: the pre-init creates a missing one and refuses one that is a
symlink or another file type (degraded boot, see below).

`/home` choice: homes persist (admin and developer keys, shell history,
staged bundles) and are shared by both slots. The image's `/home` content is a
seed, not a managed tree: a user home that already exists on `/data` is never
refreshed from a later image.

The container store is one of those homes. `iotgw-ctr` (uid/gid 968 in the
static tables, every image) runs the containers rootless; its store under
`~/.local/share/containers` is seeded from the image's `/home/iotgw-ctr` on
the first boot and then lives on `/data/home`. Files inside the store belong
to the principal or to its subordinate range (`iotgw-ctr:200000:65536` in
`/etc/subuid` and `/etc/subgid`, the same on every image), which is why both
ids are part of the `/data` format: the pre-init's re-owning of a home whose
top-level owner changed (`chown -R`) would flatten a store whose owner moved,
and a renumbered subordinate range would leave every container file owned by
nobody the engine can map. The rootful store (`/var/lib/containers`) is not
persisted: no unit uses it, `podman` from a root shell keeps nothing across
a reboot. An image that still carries a `/data/containers` directory from an
earlier rootful store can delete it by hand; nothing reads or relabels it.

### Upgrade contract for this boot path

An update onto the pre-init boot path does not carry over two kinds of state,
by decision rather than by accident:

- the retired persistent overlay uppers (`/data/overlays`, `/data/iotgw/overlay-reconcile`):
  admin edits made under `/etc`, `/root` or the old `/home` upper on an earlier
  image are deleted, and `/data/home` is seeded from the image's own `/home`
  entries (an entry already present on `/data/home` is kept);
- the rootful container store of earlier images (`/data/containers`, bound
  over `/var/lib/containers`). Containers now run rootless as `iotgw-ctr`
  with a separate store in its home; nothing migrates images from the old
  store, and an older slot booted after the switch still finds and uses
  `/data/containers` while ignoring the principal's home.

The supported path for a device that must keep such state is a reflash plus
re-provisioning. Rollback to an older slot is possible, but the state listed
here is not restored by it.

### User and group IDs are part of the `/data` format

Files on `/data` keep numeric owners. For them to belong to the same service
after an OTA update, and after an A/B rollback, every system account has one
fixed UID/GID for all images:

- the tables are `meta-iot-gateway/files/iotgw-passwd` and `iotgw-group`,
  applied by `useradd-staticids` (`iotgw-common.inc`);
- a recipe that adds an account or group without a table entry fails the build
  (`USERADD_ERROR_DYNAMIC = "error"`);
- accounts and groups created by an image's `EXTRA_USERS_PARAMS`
  (`iotgw-users.inc`, `iotgw-dev-users.inc`) carry their IDs in the command,
  because the tables do not apply there.

Adding an account: pick an unused ID below the existing system range, add it
to both tables, and keep it forever. Never renumber an existing entry: that is
a `/data` format change and needs a migration in the same change (the pre-init
re-owns only `/home`).

Images built before the tables assigned IDs dynamically, so their numbering
depended on the package set and differed between images. `/data` written by
such an image can carry wrong owners under the static IDs. Recover by
re-owning each service's state to its account by name (for example
`chown -R otbr:otbr /data/lib/thread`), or by reflashing. The tables keep the
numbering of the dev image at the time they were introduced, so a dev slot
from just before that point stays compatible in both directions.

## Degraded boot (no usable `/data`)

The pre-init waits a bounded time for the `data` partition, runs `e2fsck -p`
with a time limit and mounts it. If any of that fails, or the SELinux policy
cannot be loaded, or a bind source is unusable, it writes the reason to
`/run/iotgw/degraded` and boots anyway. Without `/data` that means the shipped
configuration only: `/etc`, `/root` and `/home` are tmpfs overlays, the
machine-id is ephemeral, and none of the `/data` binds are mounted.

The pre-init's decision is final. `/data` is not in `/etc/fstab`, so systemd
never retries the mount: it does not wait for a missing device and does not
mount a filesystem that failed `e2fsck`. Units that exist only for `/data` (the
`/data` binds, log-persist prep, machine-id, SELinux relabel, encrypted store,
TPM health) carry `ConditionPathIsMountPoint=/data` and are skipped.
`ota-certs-provision` also does work outside `/data` (`/etc/ota`, `/boot`) and
runs without that condition. On it, `RequiresMountsFor=/data` and
`After=data.mount` only order it after the mount when it exists (systemd adds
`Requires=` for a mount unit only when it has a unit file, which `/data` does
not have: it is mounted by the pre-init, not from `/etc/fstab`). The container
principal's user manager starts regardless; without `/data` its home is the
image seed on the tmpfs `/home` overlay and a container store written there is
lost at the next boot. A degraded device stays reachable through the
shipped network configuration (`iotgw-network-units`) on the verity root. Both
slots share `/data`, so a slot
switch cannot fix a storage fault and the boot counters are not spent on one:

- **Mark-good** runs as usual, except on a slot that has not yet had a healthy
  boot since it was installed (`/uboot-env/iotgw-trial-slot`, written by the
  bundle's post-install hook, removed by that slot's first healthy boot). A new
  image may itself be what breaks `/data`; it is not committed, and its boot
  counter falls back to the previous slot.
- **OTA installs** are refused: the bundle's pre-install hook fails on the
  marker, and `ota-updater.service` does not start.

Restricted recovery mode: what still works without `/data`.

- **SSH**, with host keys generated for that boot only
  (`iotgw-sshd-keys.service`). A client sees a changed host key, which is the
  signal that the device is not in its normal state. Root key login works:
  `authorized_keys` is on the verity root.
- **Ethernet**: the RP1 PCIe link's MSI controller is built into the kernel
  (`pcie-rpi5.cfg`), so RP1 still probes when the pre-init has held userspace
  back for its `/data` wait. The device keeps its usual address: eth0 and
  br0 carry the board's factory MAC, read from OTP by U-Boot, and no MAC is
  derived from the per-boot machine-id, so the DHCP lease does not change.
- **edge-healthd** runs and reports the degraded boot; it cannot save its boot
  history.
- **Bluetooth** runs on an empty `/var/lib/bluetooth`; pairings last until the
  next reboot.

## Retention and failure behavior

**journald** — configured in `meta-iot-gateway/recipes-support/iotgw-journald`:
`Storage=persistent`, `SystemMaxUse=64M`, `RuntimeMaxUse=32M`,
`MaxRetentionSec=2week`, `MaxFileSec=1week`, `Compress=yes`, `Seal=yes`,
`ForwardToSyslog=no`. The persistent journal is bounded to 64 MiB on `/data`.

**auditd** — the shipped `auditd.conf` (`meta-iot-gateway/recipes-security/iotgw-audit`,
deployed at rootfs post-processing since `auditd` owns `/etc/audit`) sets
`max_log_file=16` MiB and `num_logs=5` (an ~80 MiB nominal rotated-file budget)
with `max_log_file_action=ROTATE`. Disk-pressure actions are deliberately
**non-fatal** for an unattended gateway: `disk_full_action=ROTATE`,
`disk_error_action=SYSLOG`, and `admin_space_left_action=SYSLOG` (rather than the
package defaults of `SUSPEND`), so a full or failing `/data` cannot wedge
auditing. Audit-rule immutability (`-e`) is controlled separately by
`IOTGW_AUDIT_RULE_IMMUTABLE`.

These budgets bound normal growth; they do not guarantee that state can never be
lost. A `/data` filesystem fault is not transparent — persistent state depends on
`/data` being healthy and mounted.

## Security boundaries

`/data` is persistent but currently **plaintext ext4**. State placed on `/data`
is durable but is not confidential merely by virtue of being outside the root
slots — persistence and confidentiality are separate properties.

Any future encrypted-`/data` work (for example a LUKS-backed store) must either
preserve the same runtime-path contract described in the map above, or migrate
the backing paths deliberately, so that services continue to find their state at
the documented runtime paths.

SELinux runs **enforcing**. Every `/data` bind source carries the label of the
path it is seen at (`iotgw-file_contexts.subs`), service state owned by a
confined domain has its own type (`iotgw-file_contexts.local`), and the rest of
`/data` is `var_lib_t`. `iotgw-selinux-relabel.service` applies them whenever
the policy changes. See [SELinux](SELINUX.md) §5.3.

## Operations and verification

An SSH shell shares PID1's mount namespace, so `findmnt` from it shows the
real mounts (see
[Operations §10](OPERATIONS.md#10-ssh-sessions-mounts-and-selinux-domains)).
The checks below read PID1's view through `/proc/1` regardless, so they give
the same answer from any shell.

```sh
# /var/volatile is a true tmpfs (not overlayfs)
stat -f -c %T /proc/1/root/var/volatile            # -> tmpfs

# /var has no overlay upper
grep -q 'upperdir=[^ ,]*/overlays/var/' /proc/1/mountinfo && echo overlaid || echo clean

# stock volatile-bind units are active
systemctl is-active var-volatile-lib.service var-volatile-cache.service var-volatile-spool.service

# journal/audit mount sources resolve to /data
findmnt -no SOURCE --target /var/volatile/log/journal   # -> /dev/...p5[/log/journal]
findmnt -no SOURCE --target /var/volatile/log/audit     # -> /dev/...p5[/log/audit]

# Thread / Bluetooth binds when their features are present
grep -E '/var/lib/(thread|bluetooth)' /proc/1/mountinfo
```

Reboot survival — write a marker, reboot, and confirm it is still readable
(journald under the previous boot; audit in the `/data`-backed log):

```sh
MARK="persist-check-$(date +%s)"
logger -t persist-check "$MARK"; auditctl -m "$MARK"; journalctl --rotate; sync
reboot
# after reboot:
journalctl -b -1 | grep "$MARK"                 # journal marker, previous boot
grep "$MARK" /var/log/audit/audit.log           # audit marker on /data
```

The project on-target smoke check includes a `/var narrowing & /data
persistence` section:

```sh
scripts/run-target-checks.sh <device-ip> ota-smoke
```
