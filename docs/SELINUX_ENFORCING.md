# SELinux — enforcing-mode trials and diagnostics

Every image boots SELinux **enforcing** ([SELINUX.md](SELINUX.md) §2.4). This
document covers running a policy trial on a board, diagnosing a failure that
leaves no denial, the acceptance scripts, the design decisions behind the
local policy, and the open limitations.

It assumes the concepts in [SELINUX.md](SELINUX.md), in particular reading a
denial (§4.1) and the `staff_t`/`sysadm_t` roles (§4.2).

## 1. Running a runtime trial

A trial runs on a board in one of two ways: on an enforcing board, load a
candidate policy with `scripts/selinux/policy-trial.sh` (lost at reboot); on a permissive composition
(`IOTGW_SELINUX_MODE = "permissive"`), `setenforce 1` lasts until the next
reboot, so a power cycle is the last-resort exit if every shell is lost. Only
a `sysadm_t` shell may switch modes (SELINUX.md §4.2), so open one first and
keep it open.

```sh
newrole -r sysadm_r   # SSH root; a named admin in the sudo group uses sudo -i
                      # (console root is already sysadm_t); check id -Z, keep this shell
systemd-run --on-active=20m systemctl reboot   # safety net, armed before the switch
ausearch -m avc -ts boot | grep -c 'avc:'   # baseline
setenforce 1
#   … exercise the system: rauc status, restart services, a new SSH login …
setenforce 0                                # from the same sysadm_t shell
systemctl stop run-*.timer                  # disarm the safety net
systemctl daemon-reload; systemctl --failed # restart what failed
```

Run the trial from shells opened **before** the switch: a held session
tests what an administrator can do, a new login tests the login path, and
the two fail for different reasons. Compare every scenario with the same
scenario in permissive mode first: anything that also fails there is not
SELinux. With `dontaudit` rules active, a refused access can leave no
record at all, so a failure without a denial is still a candidate
(§1.1). A command whose output goes through a pipe reports only the last
stage's exit code unless the shell runs with `pipefail`.

Analyse after switching back, not during: under enforcing `ausearch` may be
unable to read its own configuration. Traps when collecting the denials:

- `ausearch -ts <time>` can return nothing even when `audit.log` holds
  matching records. When counts look wrong, filter the raw log by the epoch
  in `audit(<epoch>.<ms>:<id>)` instead.
- **An SSH root session cannot count denials.** It is `staff_t`, which may not
  read `audit.log` even in permissive mode, so `ausearch` prints
  `<no matches>`, and that is not zero. Read the log only from a `sysadm_t`
  shell. To analyse it elsewhere, write it to `/home` from that shell and copy
  the file off over SSH. The same holds for the target check scripts: over
  SSH as root they run in `staff_t`; on an enforcing board run them from a
  `sysadm_t` login.
- `grep 'permissive=0'` keeps only what was actually blocked; the rest of the
  log is what permissive mode let through. On a log from permissive running
  it therefore finds nothing, which reads as "ready for enforcing" when the
  opposite may be true. To see what enforcing would break, take every
  `avc:  denied` line, whatever its `permissive=` value.
- `/tmp`, `/root` and `/etc` are tmpfs or tmpfs-backed and are discarded at
  reboot, and a trial that loses every shell ends in a power cycle. Copy
  intermediate files off the board, or keep them under `/home` (bound from
  `/data/home`).
- The board logs in UTC. A `--since` time or an epoch filter typed in local
  time can point into the future and silently match nothing; check `date` on
  the board first.
- A session that stays up proves nothing about logins: SELinux checks each
  access as it happens and never re-checks running processes. Only a new
  connection tests the login path. A refused login leaves the running
  `sshd.service` up, but a restart of it under enforcing can leave it
  failed, and it stays failed after `setenforce 0`. Check
  `systemctl is-active sshd.service` (and restart it if needed) before
  closing the last open session.

A boolean can be tried the same way: `setsebool <name> 1` without `-P` lasts
until reboot.

Do not use `semodule` or `semanage` for a trial on these images. The policy
store (`/var/lib/selinux`) is in the lower layer of its overlay, and the kernel
keeps overlay `redirect_dir` off, so the store's directory rename fails with
`EXDEV`. `semodule -i` fails outright. `semodule -DB` has been seen to finish
once with that warning, after which the next `semanage` transaction failed and
the store could not be used until a reboot. `redirect_dir` stays off on purpose:
enabling it would change overlay behaviour on every persistent path to serve a
debug workflow.

`scripts/selinux/policy-trial.sh <candidate.cil> [--load user@host]` compiles the
store from a build with the candidate rules, runs the neverallow checks and
loads the result on the board. The change lasts until reboot. A permanent change
goes into the build.

### 1.1 When something fails with no denial logged

Two tools, best used together:

- **Turn the `dontaudit` rules off** (SELINUX.md §4.1.2): `semodule -DB` once,
  reproduce, read the log, then reboot to restore them. Do not run a second store
  transaction in that boot (§1). In permissive mode this alone already shows every hidden
  access, as `permissive=1`, with no risk of lockout.
- **Ask the program.** A denial can be absorbed by a fallback, so the log
  may never show the decision that failed. For sshd, start a one-shot debug
  instance in the real domain, beside the running `sshd.service`:

  ```sh
  nft add rule inet filter input meta nfproto ipv4 tcp dport 2222 accept comment \"tmp-sshd-debug\"
  systemd-run --unit=tmp-sshd-debug -p SELinuxContext=system_u:system_r:sshd_t:s0 \
      /usr/sbin/sshd -d -e -p 2222 -f /etc/ssh/sshd_config_readonly
  journalctl -u tmp-sshd-debug          # sshd's own reason
  ```

  `-f /etc/ssh/sshd_config_readonly` is what the real sshd uses (`SSHD_OPTS`
  in `/etc/default/ssh`); without it the host keys on `/data/ssh` are not
  found. `-d` serves one connection and exits. It runs independently of
  `sshd.service`, so the daemon that keeps the board reachable is never
  touched. Remove the rule afterwards (`nft -a list chain inet filter
  input`, `nft delete rule inet filter input handle <n>`); it is runtime
  only and also goes at reboot.

### 1.2 Acceptance scripts

Two scripts turn the expectations below into repeatable checks. Both print
TAP with stable case ids, so a result can be quoted in a commit body, and
exit non-zero on any `not ok`.

- **On the board, under enforcing:**
  `scripts/selinux/selinux-enforcing-target.sh [preinit|policy|all]`. Run it
  from the `sysadm_t` shell of a trial (§1); it refuses to start in any other
  domain or in permissive mode. Its DENY cases pass only when the access is
  refused, so they cannot be satisfied by a permissive boot. It restarts
  `systemd-timesyncd` and starts transient units; the header lists every side
  effect. It is registered in `scripts/run-target-checks.sh` as
  `selinux-enforcing` but not in the default set: an SSH root login lands in
  `staff_t`, where the script bails out, so the runner only works for a login
  that lands in `sysadm_t`. Otherwise run it on the serial console.
- **What `run_as` can and cannot answer.** The on-board script runs commands in
  a chosen domain through `systemd-run -p SELinuxContext=…`. That cannot answer
  "may domain X read file Y". A process enters a domain only by executing a
  file of that domain's entrypoint type (SELINUX.md §4.1.3), so `cat` or `true`
  (`bin_t`) cannot run as `rauc_t` or `sshd_t` under enforcing. A type the
  role `system_r` may not hold, such as `user_t`, fails with exit code 229
  before anything runs. A DENY case built on `run_as` therefore passes without
  testing anything. The script asks the policy instead (`sesearch -A -s X -t Y
  -c file -p read`, its `may` helper), skips any `run_as` case whose positive
  control `run_as <domain> true` fails, and leaves the runtime answer to the
  real program (a RAUC install under enforcing for the device key).
- **On the build host, against the built policy store:**
  `scripts/selinux/policy-checks-host.sh <store-root>`. It needs the store
  extracted from the built `refpolicy-mcs` packages (or copied read-only from a
  device); the script header has both commands. There is no `make` target,
  because the input is a build artifact. Case `host-pol-02` checks that the
  store declares no permissive domain.

## 2. Design decisions from the trials

### 2.1 An overlay is checked as its mounter

overlayfs checks each access twice, the second time as the domain that
mounted the overlay (SELINUX.md §4.1). An `/etc` overlay mounted by a systemd
unit runs as `mount_t`, which every `mount` command shares. `mount_t` itself
can read plain `etc_t` (it is an `nsswitch_domain`), so the denials are for
the specially typed files: unit files, `auditd_etc_t`, `shadow_t`. Granting
those to `mount_t` hands them to every mount on the system. The boolean
`allow_mount_anyfile` is a diagnostic aid only: it excludes auth types and
grants no writes, and an overlay performs copy-up writes as the mounter.

The mounter domain is whoever calls `mount(2)`: the check follows `mount_t`
only when `mount_exec_t` (`/usr/bin/mount.util-linux`) is executed with the
transition into it, so a dedicated domain that executes `mount` without
transitioning keeps the mounter rights to itself. Hence `/etc` and `/root` are
mounted by `iotgw-preinit` before systemd, and the `/var` copy-binds
(`/var/lib`, `/var/cache`, `/var/spool`, `/srv`) by `mount-copybind` in its
own domain `iotgw_overlay_t` (`iotgw.te`), never in `mount_t`.

### 2.2 SSH host keys on `/data` need the `/etc/ssh` label

Host keys persist on `/data/ssh` and are copied each boot to `/run/sshd-keys`
(PERSISTENT_STATE.md). Under the `/data` default `var_lib_t`, `sshd_t` cannot
read them and every connection is dropped before key exchange
(`kex_exchange_identification: Connection reset`). Both paths are aliased to
`/etc/ssh` in `iotgw-file_contexts.subs` (SELINUX.md §5.3), so the keys are
`sshd_key_t` and the directories `etc_t`. The fix is a label, not a rule.

Service state on `/data` that a confined domain owns carries that domain's
type in `iotgw-file_contexts.local` (`/data/edge/health`, `/data/central.raucs`,
`/data/ota/bundles`, `/data/ota-tmp`, the OTA device key); everything else is
`var_lib_t`.

### 2.3 Never relabel a layer under a live overlay

Changing labels in a layer of a mounted overlay is unsupported by overlayfs
(undefined behaviour). On this kernel the mounted directory keeps its old
type for the rest of the boot, and a new file takes its parent's type unless
a `type_transition` rule matches, so every file created in it inherits the
stale type (for example `unlabeled_t` on `/etc/ld.so.cache`, which every
program start reads). The pre-init therefore labels each upper tree before
mounting it, and the uppers live on tmpfs, outside the `/data` relabel. A file
already affected needs one `restorecon` through the overlay path (`/etc/...`),
which the overlay applies to the upper file itself.

### 2.4 RAUC runs in `rauc_t`

A service left in `initrc_t` is unconfined toward files, and the D-Bus policy
refuses administrators' calls to it, so `rauc status` fails under enforcing.
RAUC has its own domain, `rauc_t` (`iotgw.te`); `rauc status` from `sysadm_t`
is allowed, and the `rauc` CLI stays in `sysadm_t` and talks to `rauc_t` over
D-Bus.

### 2.5 sshd needs PAM

sshd is built with PAM on every image: refpolicy expects password and account
checks to go through `unix_chkpwd`, which enters `chkpwd_t`, a domain allowed
to read the shadow file. With the boolean `authlogin_pam` on (the default),
`sshd_t` has no read access to `shadow_t`, and a `dontaudit` rule hides the
denial. Turning `authlogin_pam` off would give `sshd_t` the read, but it lets
every PAM-using domain read the shadow file.

Without PAM this breaks key logins for root, not only passwords. sshd decides
whether an account is locked before it looks at any key: it reads the user's
shadow entry and treats a password field starting with `!` as locked (OpenSSH
`platform_locked_account()`). When `/etc/shadow` cannot be read, glibc falls
through to the next `shadow:` source in `/etc/nsswitch.conf`, `systemd`, which
synthesises an entry for `root` with the password `!*`
(`getent -s systemd shadow root`). sshd then logs
`User root not allowed because account is locked`, treats root as an invalid
user and never reads `authorized_keys`. The decision itself leaves no denial:
a fallback inside glibc replaces the failed read (§1.1).

The `UsePAM` line sshd warns about at startup ("Unsupported option") comes
from meta-selinux's `50-selinux.conf`, which assumes a PAM build. Root
password logins are refused by design (`PermitRootLogin prohibit-password`
in `99-iotgw.conf`), so a password prompt after a failed root key is the
client trying its next method, not a way in.

### 2.6 No persistent `/etc` layer

A persistent upper layer on `/data` would override the dm-verity–authenticated
`/etc` of every later slot, including the compiled policy and anything
a policy trial wrote. `/etc` and `/root` therefore have a
tmpfs upper (`iotgw-preinit`), and persistent state is the explicit bind list
in [PERSISTENT_STATE.md](PERSISTENT_STATE.md). Policy trials (§1) still work;
a reboot discards them.

## 3. Open limitations

Every image boots enforcing, with no permissive domain in the policy. The
rootfs build fails if the store declares a permissive domain not listed in
`IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED` (empty by default;
`iotgw-rootfs.bbclass`), and `policy-checks-host.sh` case `host-pol-02` checks
a built store; on a device `seinfo --permissive` prints nothing. A
`permissive <domain>;` statement applies whatever the kernel configuration
(`security/selinux/ss/services.c`, `permissive_map`);
`CONFIG_SECURITY_SELINUX_DEVELOP` governs only the global switch.

- **RAUC cannot unmount the FAT boot partition.** Under enforcing `rauc_t` is
  refused the unmount and the hook falls back to remounting it read-only. The
  FAT dirty bit does not depend on it: a clean unmount does not clear that bit,
  `fsck.vfat -a` does, and `/boot` and `/uboot-env` are checked at boot (fstab
  pass 2).
- **No recovery boot path.** The kernel command line is signed into the slot
  FIT, so there is no `selinux=0` or `enforcing=0` fallback; recovery from a
  slot that fails under enforcing is the A/B boot-counter fallback.
- **Prod has no runtime switch to permissive.** `kas/uboot-prod-hardening.yml`
  removes `CONFIG_SECURITY_SELINUX_DEVELOP`, so `setenforce` and `enforcing=`
  have no effect there and recovery from a bad policy is the A/B fallback. Dev
  and desktop keep it, so `setenforce 0` works from a `sysadm_t` shell.
- **Prod has not been booted enforcing on hardware.** It carries the same
  policy as dev and desktop, with less software.
- **Boot-time oneshots run in `initrc_t`.** Every long-running daemon has a
  domain of its own, but a oneshot whose executable is labelled `bin_t` runs in
  `initrc_t`, which is unconfined toward files (SELINUX.md §4.1.1). That covers
  this layer's `iotgw-machine-id`, `iotgw-log-persist-prep`, `iotgw-sshd-keys`,
  `iotgw-selinux-relabel`, `iotgw-pstore-prune`, `iotgw-bootstage`,
  `ota-certs-provision`, `boot-backup-prune` and `ota-updater`, and upstream helpers refpolicy leaves unlabelled
  (`audit-rules`, `sysstat`, `hciuart`, `selinux-init`, `systemd-remount-fs`).
  To list them on a device: for each enabled unit, compute the domain of its
  `ExecStart` from `init_t` with `security_compute_create`.
- **The OTBR REST API on port 8081 is unauthenticated** and returns the
  Thread network key. It binds loopback only and the firewall drops 8081 off
  `lo` (OTBR.md), so only processes on the gateway reach it.

OTA slots need no extra step: the bundled rootfs is built with
`selinux-image`, so each slot carries its labels inside the dm-verity image,
and a policy or file-context change relabels `/data` on the new slot's first
boot (SELINUX.md §5.3).
