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
persistent OverlayFS uppers on `/data` (for `/etc`, `/home`, `/root`), dedicated
`/data`-backed bind mounts (for the small set of must-persist runtime state), or
the stock OpenEmbedded volatile model (RAM-backed, cleared each boot).

`/var` is intentionally **not** an OverlayFS mount. A blanket overlay over the
whole `/var` captured `/var/volatile` (so the tmpfs was shadowed and "volatile"
data persisted), persisted all of `/var` when only a small subset needs to
survive reboot, and prevented the stock `volatile-binds` from taking effect.
Removing the `/var` overlay restores true-volatile semantics and confines
persistence to an explicit, bounded set of `/data`-backed paths.

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
- `/etc`, `/home`, and `/root` keep persistent OverlayFS uppers under
  `/data/overlays/<name>/{upper,work}`. `/var` does not. The `/etc` upper has its
  own drift-control model across updates — see
  [Overlay Reconciliation](OVERLAY_RECONCILIATION.md).

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
| pstore/crash | `/var/lib/systemd/pstore` | `/data/crash/pstore` | bind mount (`var-lib-systemd-pstore.mount`) | pre-existing; gated by `IOTGW_ENABLE_PSTORE_PERSIST` |
| SSH host identity | `/data/ssh` | `/data/ssh` | direct `HostKey` paths in the read-only-rootfs sshd config | keys generated once |
| Mosquitto retained state | `/data/mosquitto` | `/data/mosquitto` | `persistence_location` in `mosquitto.conf` | retained messages/sessions |
| TPM2 PKCS#11 token DB | `/data/tpm2_pkcs11` | `/data/tpm2_pkcs11` | `IOTGW_TPM2_PKCS11_STORE` (provider/provisioning config) | OTA mTLS device identity |
| OTA cert provisioning state | `/data/ota-certs-provision.state`, `/data/ota-certs-provision.done` | same | direct script paths | provision id/replay + completion stamp |
| First-boot provisioning stamp | `/data/iotgw-provision.done` | same | direct script path | prevents re-running provisioning |
| OpenThread dataset | `/var/lib/thread` | `/data/lib/thread` | bind mount (`var-lib-thread.mount`) | present only with OTBR builds |
| Bluetooth adapter identity + pairings | `/var/lib/bluetooth` | `/data/lib/bluetooth` | bind mount (`var-lib-bluetooth.mount`) | gated on the `bluetooth` distro feature |
| InfluxDB 3 data | `/data/influxdb3` | `/data/influxdb3` | `INFLUXDB3_DATA_DIR` service config | only when the optional InfluxDB 3 recipe is installed |
| Container storage | `/var/lib/containers` (stub) | `/data/containers/storage` | `graphroot` in `storage.conf` | only with the container stack |
| `/etc`, `/home`, `/root` | same | `/data/overlays/<name>/{upper,work}` | OverlayFS | writable-rootfs uppers |

Everything else under `/var` is volatile. Notably, `/var/lib/systemd/random-seed`
and `/var/lib/systemd/timesync/clock` are not persisted; the RTC provides a clock
floor and systemd reseeds entropy.

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

Because `/var/lib` is now writable only after `var-volatile-lib.service` lands,
`systemd-timesyncd` (which creates `StateDirectory=systemd/timesync`) is ordered
after that unit via a drop-in; without it, timesyncd fails
`238/STATE_DIRECTORY` early in boot and only recovers once the bind is up.

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

SELinux is enabled in **permissive** mode on this branch, and the narrowing was
validated in that mode. The new `/data`-backed persistent paths do not yet carry
dedicated SELinux file contexts; correct persistent-path labeling and policy are
prerequisites for enforcing mode and are follow-up work. See
[SELinux](SELINUX.md).

## Operations and verification

Read mounts from PID1's view — an interactive SSH session can sit in a
service-hardening mount namespace that misreports mounts (see
[Operations §10](OPERATIONS.md#10-ssh-sessions-and-mount-namespaces)).

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
