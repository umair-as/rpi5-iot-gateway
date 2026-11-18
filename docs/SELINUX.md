# SELinux 101 — concepts and the local wiring

This is the working-knowledge primer for anyone who maintains, debugs, or
flips the SELinux posture on this distro. It assumes you've used Linux but
not SELinux. The first half explains the concepts; the second half maps
them to the exact files in this tree. Running a runtime trial and diagnosing
denials under enforcing: [SELINUX_ENFORCING.md](SELINUX_ENFORCING.md).

SELinux is the distro's **active MAC**, always on. Every image boots
**enforcing** (`IOTGW_SELINUX_MODE`, §2.4); a composition can opt into
permissive to collect the access surface of new software before its policy
exists. The shipped policy declares no permissive domain. AppArmor is not
carried.

## 1. Why LSM exists

The traditional UNIX permission system is **discretionary access control**
(DAC). The file owner decides who can read/write/execute. uid 0 (root)
bypasses all checks. This is enough for a single-user workstation but
leaves no room for a security policy that the operator gets to enforce
*above* the application — and offers no answer to the "confused deputy"
problem (a privileged process being tricked into using its privilege
against the user).

**LSM** (Linux Security Module) is the kernel framework that adds a second
layer: **mandatory access control** (MAC). Before any access check
completes, the kernel calls into a stack of LSM hooks. Each hook can DENY
the access regardless of what DAC said. So even root can be restricted:
"this process is in security domain X — it may only open files labelled Y."

```
   userspace:  open("/etc/passwd", O_RDONLY)
                          |
                          v
                  +----------------+
                  | syscall layer  |
                  +----------------+
                          |
                          v
                  +----------------+
                  | DAC checks     |     classic UNIX layer
                  | uid / gid /    |     -- owner decides
                  | mode bits      |
                  +----------------+
                          |
                  (DAC says ok)
                          |
                          v
                  +----------------+
                  | LSM hooks      |     MAC layer
                  |  Lockdown      |     -- operator's policy
                  |  Yama          |        wins over root
                  |  BPF           |
                  |  Landlock      |
                  |  **SELinux**   |     -- this is where the
                  +----------------+        access actually
                          |                 gets allowed/denied
                 (any LSM may deny;
                  SELinux usually does
                  the deciding)
                          |
                          v
                   file descriptor
```

LSM is a stack. Multiple LSMs run side-by-side:

| LSM | What it does | In this build? |
|---|---|---|
| Lockdown | Reduces kernel attack surface (no /dev/mem, no kexec, no unsigned module loading, ...) | yes |
| Yama | Restricts ptrace to parent-child relationships | yes |
| BPF | Constrains eBPF program loading | listed in CONFIG_LSM |
| Landlock | Sandboxing API that unprivileged processes can use on themselves | yes |
| AppArmor | Path-based MAC (one profile per binary) | **no** — not carried |
| **SELinux** | **Type-enforcement MAC (labels everywhere)** | **yes — the active MAC** |
| SMACK / TOMOYO | Alternative MACs | no |

Only **one** of {SELinux, AppArmor, SMACK, TOMOYO} can be the active MAC
at a time — they're "exclusive" LSMs. The non-exclusive ones
(Lockdown, Yama, BPF, Landlock) stack alongside.

The `CONFIG_LSM=` kernel string defines initialization ORDER, set to:

```
CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"
```

SELinux is last so its hooks see context already resolved by the others.

## 2. SELinux concepts

> **If you read one thing.** SELinux compares tags, never paths, owners or
> mode bits. Every process carries a type (its *domain*, e.g. `sshd_t`) and
> every file carries a type (e.g. `sshd_key_t`). The policy is a list of
> `allow <process type> <file type> : <class> <action>` lines, and anything
> not listed is denied.
>
> A file has two labels that are easy to confuse:
>
> | | Where it lives | See it with |
> |---|---|---|
> | The label the file **has** | stored on the file (`security.selinux` xattr) | `ls -Z` |
> | The label it **should** have | a path-pattern table (`file_contexts`) | `matchpathcon <path>` |
>
> Nothing keeps them in step. `restorecon` copies the *should* onto the file;
> `semanage fcontext` edits the table and touches no file.
>
> Picture a warehouse. Workers (processes) wear coloured badges, boxes (files)
> carry coloured stickers, and the rule book says which badge may open which
> sticker. The catalogue (`file_contexts`) says which sticker each shelf gets,
> and `restorecon` walks the shelves re-stickering boxes to match it. A box
> moved to a shelf the catalogue does not list gets a generic sticker, and the
> worker who needs it is turned away. That is the `/data/ssh` host key
> failure in [SELINUX_ENFORCING.md](SELINUX_ENFORCING.md) §2.2.
>
> The sticker is therefore the permission. A wrong sticker that is too
> *narrow* breaks a service, loudly. A wrong sticker that is too *broad*
> silently grants access: tag a private key with a type many domains may
> read, and all of them can read it, with no denial to warn you. Fix labels
> to the specific type the policy intends; never relabel to a broad type to
> make a denial go away.

### 2.1 Everything has a label

Every process and every kernel object (file, socket, sysfs entry, IPC
endpoint, ...) carries an SELinux label. A label has four fields:

```
   system_u   :   object_r   :   ssh_home_t   :   s0
   ^^^^^^^^       ^^^^^^^^       ^^^^^^^^^^       ^^
      |              |                |            |
     user           role             TYPE        level
   (RBAC)        (RBAC)         (TE — the part   (MCS/MLS,
   advanced     advanced         policy actually  almost
                                    decides on)   always s0
                                                  here)
```

For most policy decisions only the **type** matters. The others are for
advanced setups (multi-category / multi-level security).

### 2.2 Type Enforcement (TE) — the core model

- **Subject** (a running process) has a **domain**, which is a type like
  `sshd_t`, `httpd_t`, `init_t`.
- **Object** (a file, socket, ...) has a type like `etc_t`, `var_log_t`,
  `tmp_t`.
- The policy is a long list of `allow` rules: `allow DOMAIN
  OBJECT_TYPE:OBJECT_CLASS PERMISSION`.

If no rule says `allow sshd_t var_log_t:file open`, sshd can't open files
of type `var_log_t`. Default-deny. There are no "groups" or "users" in
policy — only types and the type-transition rules that move processes
between domains as they exec new binaries.

### 2.3 Where labels come from

| Object | Label source |
|---|---|
| Files on disk | extended attribute `security.selinux` (xattr). Set at build time by `selinux-image.bbclass` (the read-only root); on `/data` by `iotgw-selinux-relabel.service` (§5.3), or by hand with `restorecon` |
| Processes | Inherited from parent, OR set by a `type_transition` rule when an executable runs |
| Sockets, IPC, /proc, /sys | Computed per-call by policy |

### 2.4 Operating modes

| Mode | LSM hooks called? | Denials enforced? | Denials logged? |
|---|---|---|---|
| Disabled | no | no | no |
| Permissive | yes | **no** | **yes** (to audit) |
| Enforcing | yes | yes | yes |

Switching:
- Kernel cmdline: `selinux=0` (disabled), `enforcing=0` / `enforcing=1` (the
  kernel accepts them, but the command line here is signed into the slot FIT,
  so they are not available on a deployed image)
- Runtime: `setenforce 0|1` (permissive <-> enforcing only — can't go back
  to disabled without reboot)
- The boot default comes from `/etc/selinux/config`, which refpolicy ships
  from `DEFAULT_ENFORCING`. `iotgw-common.inc` sets it from the switch
  `IOTGW_SELINUX_MODE` (default `enforcing`, for every image). A composition
  may set it to `permissive` to collect the access surface of new software
  before its policy exists. The file is part of the refpolicy package, which
  every image of a composition shares, so the mode is per composition, not per
  image recipe.
- The kernel command line is signed into the slot FIT, so a boot parameter is
  no recovery path. A slot that fails to boot under enforcing falls back to the
  other slot through the A/B boot counters.

**Bringing up policy for new software** is: build a composition with
`IOTGW_SELINUX_MODE = "permissive"` -> run the real workload -> collect AVC
denials with `ausearch` -> add rules or labels to `iotgw.te`/`.fc` -> repeat
until denials stop -> build enforcing again.

### 2.5 Reference policy variants

SELinux ships with a reference policy ("refpolicy") — a big collection of
TE rules covering common Linux daemons. Available variants:

| Variant | Use case |
|---|---|
| `refpolicy-minimum` | Login + getty only. Too little coverage for real systems. |
| `refpolicy-targeted` | Fedora-style: confine services, leave user shells unconfined. |
| `refpolicy-standard` | Full module set, no sensitivity dimension. Its 3-field contexts are rejected by the container runtime (see below). |
| `refpolicy-mcs` | **This distro's pick.** Same full module set as standard plus a single non-hierarchical sensitivity level (Multi-Category Security). |
| `refpolicy-mls` | Multi-Level Security (Bell-LaPadula). Very strict. Not a fit. |

The pick lives in `iotgw-common.inc`:
```
PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"
```

**Why MCS and not standard.** This image ships Podman. The container
runtime (podman / netavark / container-selinux) relabels its netns and
overlay directories with 4-field contexts ending in an MCS category — e.g.
`system_u:object_r:container_file_t:s0`. A non-MCS policy has only three
context fields (user:role:type), so the kernel LSM rejects the 4-field
label at `lsetxattr()` with `EINVAL`. This is a context-*validity* check,
not an access decision, so it fires even in permissive mode — it cannot
be worked around with `--security-opt label=disable` or by setting the
policy permissive. MCS adds the single `s0` sensitivity level the labels
require, with the same module coverage as standard.

## 3. What `meta-selinux` provides

The layer is essentially three things: userspace, policy, and the bbappends
that activate libselinux in oe-core recipes.

### Userspace (via `packagegroup-core-selinux`)
- `libselinux` / `libsemanage` / `libsepol` — kernel API, policy
  management, policy database parsing
- `policycoreutils` — `sestatus`, `setfiles`, `restorecon`, `fixfiles`,
  `semodule`, `semanage`, `runcon`, `secon`
- `selinux-python` — `audit2allow`, `audit2why`, `sepolgen`. Daily drivers.
- `setools` — `sesearch`, `seinfo`. Advanced policy inspection.
- `selinux-autorelabel` — systemd unit that runs `restorecon -R /` on
  first boot when `/.autorelabel` exists, then deletes the marker. Masked on
  this distro (`iotgw-rootfs.bbclass`): the root is labelled at build time and
  cannot hold `/.autorelabel` (§5.3).

### Policy
- The 5 refpolicy variants above. `refpolicy-mcs` is required via
  `PREFERRED_PROVIDER_virtual/refpolicy`.

### bbclass: `selinux-image.bbclass`
Hooks `do_rootfs` to run `setfiles` against the policy's `file_contexts`
file, labelling every file **at build time**. Inherited by all image
variants via `IMAGE_CLASSES += "selinux-image"` in
`iot-gw-image-base.inc`. Without it, files ship unlabelled
(= `unlabeled_t`) and the first boot pays a slow full autorelabel.

### bbappends — applied automatically

meta-selinux ships a `<recipe>_%.bbappend` for every upstream recipe that
knows how to link libselinux (`openssh`, `dbus`, `systemd`, `sudo`,
`eudev`, `util-linux`, `shadow`, `PAM`, `coreutils`, `busybox`, ...). Each
is a one-liner that inherits `enable-selinux` **only when `DISTRO_FEATURES`
contains `selinux`**. The upstream recipe already carries a dormant
`PACKAGECONFIG[selinux]`; meta-selinux flips the switch.

**Practical takeaway: enabling SELinux does NOT require touching any of
those recipes.** Two things trigger all of it:

1. `meta-selinux` present in `rpi5.yml` (so bitbake sees the bbappends)
2. `DISTRO_FEATURES += " selinux"` in `iotgw-common.inc` (so they fire)

## 4. Daily commands

```sh
getenforce                  # Permissive | Enforcing | Disabled
sestatus                    # mode, policy variant, loaded modules
id -Z                       # your own process label
ls -Z /etc/passwd           # file label
ps -eo label,pid,comm       # subject labels of running procs

# AVC denial triage
ausearch -m AVC -ts boot              # all denials since boot
ausearch -m AVC -ts today | audit2allow -M iotgw-fix
   # -> emits iotgw-fix.te (human-readable) and iotgw-fix.pp (binary module)
semodule -i iotgw-fix.pp              # install module
semodule -l | head                    # list loaded modules
# A module installed with semodule -i lives in the volatile policy store and is
# gone after a reboot; a permanent rule goes into policy/iotgw.te.
# Runtime semodule -i is not supported on the images today: the store is in the
# lower layer of the /var/lib overlay and the kernel has overlay redirect_dir
# off, so its commit fails with EXDEV. Trial with scripts/selinux/policy-trial.sh
# (SELINUX_ENFORCING.md section 1) and ship policy changes in the image.

# Re-apply labels
restorecon -Rv /var/log              # relabel a tree
rm /data/.iotgw-selinux-labels; systemctl restart iotgw-selinux-relabel.service   # full /data relabel (never /.autorelabel, §5.3)

# Inspect / change file contexts
semanage fcontext -a -t var_log_t '/data/log(/.*)?'   # trial only: lost at reboot, and it regenerates file_contexts without the iotgw entries (§5.3)
restorecon -Rv /data/log                              # apply it

# Per-domain permissive (a policy statement; independent of CONFIG_SECURITY_SELINUX_DEVELOP)
semanage permissive -a httpd_t        # make httpd_t permissive, rest enforcing
semanage permissive -d httpd_t        # take it back

# Toggle global mode
setenforce 0     # -> Permissive
setenforce 1     # -> Enforcing

# Find which rule allowed something
sesearch --allow -s sshd_t -t var_log_t
```

**Always review `audit2allow` output before installing.** Auto-allowing
everything AVC denies defeats the point. Three outcomes for any denial:
(a) the rule is legitimate — install the module; (b) the file label is
wrong — fix it with `semanage fcontext` + `restorecon`, no rule; (c) the
app is misbehaving — fix the app, not the policy.

### 4.1 Reading one denial

One denial in `ausearch -m avc` output is a group of records sharing one
event id (`audit(…:917)`). Two of them carry the answer:

```
type=SYSCALL … comm="ausearch" exe="/usr/sbin/ausearch" subj=root:sysadm_r:sysadm_t:s0-s0:c0.c1023
type=AVC … avc:  denied  { read } for … name="auditd.conf" dev="dm-0"
          scontext=system_u:system_r:mount_t:s0
          tcontext=system_u:object_r:auditd_etc_t:s0 tclass=file permissive=0
```

Read the AVC line as a sentence: **`scontext` tried `{ read }` on a
`tclass` labelled `tcontext`, and was refused.** Then:

| Field | Question it answers |
|---|---|
| `scontext` | Which domain was checked. Usually the process, but see below |
| `tcontext` | What label the object carries. `unlabeled_t` means it has none: a labelling bug, never a rule to add |
| `tclass` + `{ … }` | What kind of object, and which operation |
| `permissive=` | `1`: logged but allowed. `0`: actually blocked |
| `subj=` (SYSCALL line) | The process that made the system call |
| `name=`, `dev=` | Which file, on which device |

When `subj` and `scontext` differ, the check was not made against the
calling process. Here the caller was `sysadm_t` but the denial names
`mount_t`: the file sits on an overlayfs (§5.3), and overlayfs checks every
access twice: once as the caller against the overlay file, and once **as
whoever mounted the overlay** against the real file underneath. The example
comes from an `/etc` overlay mounted by a systemd mount unit, which runs as
`mount_t`. On the current image `/etc` and `/root` are mounted by
`iotgw-preinit` before systemd, and the `/var` copy-binds by `mount-copybind`
in its own domain `iotgw_overlay_t` (`policy/iotgw.te`).

`audit2allow -w` explains denials in words, and `audit2allow -M` writes
rules for them. Both are hints: check a suggestion against the policy
before acting on it. On the denials above, `-w` suggests the boolean
`allow_mount_anyfile`. Despite its name it does cover them, as `sesearch`
shows:

```
$ sesearch -A -s mount_t -t systemd_unit_t -c dir -p read
allow mount_t non_auth_file_type:dir { ioctl lock read }; [ allow_mount_anyfile ]:True
```

The rule exists; the trailing `[ boolean ]:True` means it only applies while
that boolean is on (`getsebool allow_mount_anyfile`). It grants reads of
every *non-auth* file type, and nothing else: not `unlabeled_t`, not writes
(overlayfs copies a file into the upper layer as the mounter when it is first
changed), and not auth files such as `shadow_t`.

The `shadow_t` exclusion shows why a denial is not automatically a rule to
add. With `/etc` mounted by a unit in `mount_t`, a password login over SSH
produces `mount_t read shadow_t (shadow) by sshd-session`. Through an overlay the
mounter check runs first; it failed, and the access stopped there, so the
caller's own check never ran (for sshd it would fail as well, see
SELINUX_ENFORCING.md §2.5). Allowing `mount_t` to read `shadow_t` would fix
the first check, but
`mount_t` is shared: every `mount` command on the system runs in it. The rule
would hand the password hashes to all of them. The mounter of an overlay
should be privileged, but private to that one job. When a fix would widen a
shared domain's access to an auth file, change the design, not that domain.

### 4.1.1 Three more pieces of the rule book

- **Attributes** are named groups of types. `typeattributeset
  non_auth_file_type (… sshd_key_t …)` puts `sshd_key_t` in a group, and one
  rule naming the group covers every member. That is how a single boolean
  rule can cover thousands of file types while leaving `shadow_t`, which is
  not in the group, outside. `seinfo -a <attribute> -x` lists the members.
- **Process transitions** decide a new process's domain the same way
  `type_transition` decides a new file's type: from the starting domain and
  the program file's type. `type_transition init_t bin_t:process initrc_t`
  is why any service whose program is plain `bin_t` runs as `initrc_t`. A
  service gets its own domain only when a module gives its program its own
  exec type and a transition into the domain.
- **`dontaudit` rules** deny without logging (§4.1.2).

A domain's powers come mostly from its attributes, so `seinfo -t <domain> -x`
is the first place to look, and `sesearch -A -s <domain> -t <type>` gives
the final answer. Not every attribute grants something: some are markers.
`can_read_shadow_passwords` lists about 90 of 4,600 types, `sshd_t`
included, yet no allow rule comes from it, and `sesearch` shows `sshd_t`
may read `/etc/shadow` only through a rule that is off while the boolean
`authlogin_pam` is on. Refpolicy expects password checks to go through PAM's
helper `unix_chkpwd`, whose domain `chkpwd_t` may read the file.

Who may read the hashes is a short list of programs whose job needs them
(`chkpwd_t`, `passwd_t`, `useradd_t`). Neither `staff_t` nor `sysadm_t` may;
`sysadm_t` may relabel the shadow file but not read it. Root changes a
password by running `passwd`, which enters a domain that may. Access belongs
to the program doing a job, not to the user.

The exception is `initrc_t`, the domain every service without its own runs
in. It is a `files_unconfined_type`, which may read and write every file,
shadow included. A service left in `initrc_t` is unconfined toward files,
which is the strongest reason to give the gateway's own services domains.

### 4.1.2 `dontaudit`: denied without a record

auditd is not involved. A `dontaudit` rule sits in the rule book beside the
allow rules and tells the kernel not to create the denial record at all, so
auditd never receives one:

```
process tries an access
        │
        ▼
kernel SELinux checks the rule book
        │
   ┌────┴─────────────┬──────────────────────────────┐
 allow rule        no allow rule                no allow rule
 matches           (normal case)                + a dontaudit rule matches
   │                  │                              │
 allowed           denied (enforcing)             denied (enforcing)
 no record         AVC record ──► auditd          no record anywhere
```

| | Enforcing | Permissive |
|---|---|---|
| An allow rule matches | allowed, nothing logged | allowed, nothing logged |
| No rule matches | **denied**, logged (`permissive=0`) | allowed, logged (`permissive=1`) |
| A `dontaudit` rule matches | **denied, not logged** | **allowed, not logged** |

The rule has the same shape as an allow rule
(`dontaudit sshd_t some_type:file read;`) and never grants anything. It
exists because programs make many harmless attempts they do not need, such as
scanning search paths or probing other processes' `/proc` entries.
Refpolicy carries many thousands of these rules (`seinfo`); without them the
real denials would drown. `sesearch --dontaudit -s <domain>` lists the rules
for one domain.

The cost is visibility:

- Under enforcing, a silenced denial that does matter shows up as a failure
  with no denial in the log. Rebuild the policy with the rules disabled
  (`semodule -DB`), reproduce, read, then restore them (`semodule -B`).
- In permissive, a silenced access succeeds and leaves no trace, so it is
  missing from the "what would break" list until an enforcing trial breaks
  it.

It does not help an attacker get in. The access is still denied under
enforcing, and the rules are fixed when the policy is built: adding one at
runtime means loading a new policy, which only an administrator domain may
do. What it can hide is a *failed* attempt. That is why access to files that
matter is also watched outside SELinux, with audit file watches
(`auditctl -w /etc/shadow -p wa`). Those log through the audit subsystem
whatever the policy says.

### 4.1.3 Entering a domain: entrypoint and role

A process does not choose its domain. It gets one by executing a file, and
only a file whose type is an **entrypoint** of the target domain will do:
`rauc_t` is entered through the `rauc` binary (`rauc_exec_t`), `sshd_t`
through `sshd` (`sshd_exec_t`). Executing `/usr/bin/cat` (`bin_t`) can never
start a process in `rauc_t`, whoever asks. Under enforcing the attempt is
refused with a denial that names the permission:

```
denied { entrypoint } … path="/usr/bin/true.coreutils" scontext=…:rauc_t:s0 tcontext=…:bin_t:s0 tclass=file
```

The **role** limits which domains a context may hold at all. A context is
`user:role:type:level`, and the policy lists the types each role may use:
`user_t` belongs to `user_r`, services to `system_r`. A context such as
`system_u:system_r:user_t:s0` is invalid, and anything asked to start a
process with it fails before running a single instruction. systemd reports
that as exit code 229.

Both facts limit test tools. "Run `cat` as `rauc_t` and see whether it may
read the key" cannot work: the command never enters `rauc_t`. Ask the policy
instead, `sesearch -A -s rauc_t -t iotgw_ota_key_t -c file -p read`, and
leave the runtime answer to the program that does the job.

### 4.2 Roles: why root cannot always run `setenforce`

Root is not one thing under SELinux. Logging in over SSH lands in
`root:staff_r:staff_t`, an administrator domain that may **not** switch
enforcing off. Only domains such as `sysadm_t` carry that permission
(`seinfo -a can_setenforce -x` lists them). A shell switches role with
`newrole`, which asks for the user's password:

```sh
id -Z                  # root:staff_r:staff_t:…
newrole -r sysadm_r
id -Z                  # root:sysadm_r:sysadm_t:…  — this shell may setenforce
```

A named administrator account steps up with sudo instead: the sudoers rule
for the admin group carries `ROLE=sysadm_r TYPE=sysadm_t`, so `sudo -i`
lands in `sysadm_t` and the audit log names the person, not just root.
`newrole` is the path for root over SSH and for accounts outside the `sudo`
group.

Services started by systemd cannot do it either (`init_t`, `initrc_t`), so
a timer that "switches back after ten minutes" does not work. Open the
`sysadm_t` shell **before** going enforcing, and keep it open. The safety
net that does work is a timer that reboots
(`systemd-run --on-active=20m systemctl reboot`): init may reboot, and the
board comes back in the image's default mode.

The starting role depends on how you log in, not on who you are. `seusers`
maps Linux `root` to the SELinux user `root`, which may hold `staff_r` and
`sysadm_r`. Members of the `sudo` group map to `staff_u`
(`%sudo:staff_u:s0-s0:c0.c1023`, written by the refpolicy-mcs bbappend), which
may also hold `sysadm_r`; every other account maps to `user_u`. At login, `pam_selinux` looks up the login program's domain and
takes the first listed role that user may hold:

| Login | Login domain | Looked up in | Lands in |
|---|---|---|---|
| Serial console (`login`) | `local_login_t` | `contexts/users/root` | `sysadm_t` |
| SSH | `sshd_t` | `default_contexts` (the `sshd_t` line in `contexts/users/root` is commented out) | `staff_t` |

So a console login is already `sysadm_t`, and an SSH login has to ask with
`newrole`. That is deliberate: a remote session gets less power until it
re-authenticates. Keep it that way rather than uncommenting the `sshd_t`
line.

### 4.3 Reading `sesearch`: executing a program from the SSH shell

`sesearch` inspects policy rules. It does not run the program being queried
or change policy. Without a policy-file argument, it searches for the policy
running on the local system.

```sh
sesearch -A -s staff_t -t bin_t -c file -p execute
```

| Argument | Meaning in this query |
|---|---|
| `-A` | Search access-vector allow rules; current SETools includes `allowxperm` too. Use `--allow` for ordinary `allow` rules only. |
| `-s staff_t` | Source: the requesting process's domain |
| `-t bin_t` | Target: the accessed file's type |
| `-c file` | Object class: a regular file |
| `-p execute` | Select rules whose permission set includes `execute` |

In plain English: **which rules grant a process in `staff_t` execution
permission on a file labelled `bin_t`?** The pattern is “who → action →
object”. For other classes, the target need not be a file: with
`-c process -p transition`, it is the destination process domain.

Example output from an SSH root login on the gateway (the exact rule may
differ between policy builds):

```text
# id -Z
root:staff_r:staff_t:s0-s0:c0.c1023
# ls -Z /usr/bin/id
system_u:object_r:bin_t:s0 /usr/bin/id
# sesearch -A -s staff_t -t bin_t -c file -p execute
allow staff_t bin_t:file { entrypoint execute execute_no_trans getattr ioctl lock map open read };
```

The search prints the **whole matching rule**, not just `execute`. Matching
also follows type-attribute membership by default, so other queries may
return attribute names rather than the literal types you supplied. These
search semantics are documented in the upstream
[SETools `sesearch` manual](https://github.com/SELinuxProject/setools/blob/main/man/sesearch.1).

Three permissions in this result are especially useful to distinguish:

| Permission | Meaning |
|---|---|
| `execute` | Allows executing a file of this type; other checks still apply. |
| `execute_no_trans` | Allows executing it while retaining the current domain. |
| `entrypoint` | Allows this file type to serve as an entry point into the rule's source domain (`staff_t` here), when a transition into that domain is otherwise selected and permitted. |

`entrypoint` does not cause a transition, and `execute_no_trans` does not
force every execution to stay in the same domain. See the SELinux Notebook's
[file permissions](https://github.com/SELinuxProject/selinux-notebook/blob/main/src/object_classes_permissions.md#file).

`strace -e trace=execve /usr/bin/id` shows a successful
`execve`, and `id` printed:

```text
uid=0(root) gid=0(root) groups=0(root) context=root:staff_r:staff_t:s0-s0:c0.c1023
```

So **that invocation of `id` ran in `staff_t`**, consistent with execution
without a domain transition. The binary's file type remains `bin_t`; a
process does not simply adopt the type of the file it executes.

A matching rule is not an end-to-end permission verdict. Conditional rules
may depend on Booleans; constraints, directory access, executable/library
access, UNIX permissions and other security checks can also matter.
Furthermore, successful execution in permissive mode does not establish
that all SELinux checks would pass in enforcing mode. Check `getenforce`
and any per-domain permissive setting when interpreting runtime evidence.

### 4.4 Connecting file execution to the password-checking helper

Example output:

```text
# sesearch -A -s chkpwd_t -t shadow_t -c file
allow chkpwd_t shadow_t:file { getattr ioctl lock open read };
# command -v unix_chkpwd
/usr/sbin/unix_chkpwd
# ls -Z /usr/sbin/unix_chkpwd
system_u:object_r:chkpwd_exec_t:s0 /usr/sbin/unix_chkpwd
# sesearch -A -s sshd_t -t chkpwd_t -c process -p transition
allow sshd_t chkpwd_t:process transition;
```

Read these as three separate facts:

- `chkpwd_t` has an allow rule for reading `shadow_t` files. The returned
  permission set includes `open` and `read`, but no `write`.
- The helper executable has file type `chkpwd_exec_t`. That is distinct
  from the process domain `chkpwd_t`.
- Policy permits a process in `sshd_t` to transition into `chkpwd_t`.
  This rule does not itself select the helper executable or cause a transition.

For an automatic transition on execution, inspect the selection rule and
the source-execute and destination-entrypoint permissions too:

```sh
sesearch -T -s sshd_t -t chkpwd_exec_t -c process
sesearch -A -s sshd_t -t chkpwd_exec_t -c file -p execute
sesearch -A -s chkpwd_t -t chkpwd_exec_t -c file -p entrypoint
```

These are follow-up queries, **not results already observed**. A selection
rule for this path would have the form:

```text
type_transition sshd_t chkpwd_exec_t:process chkpwd_t;
```

Here the rule's target is the executable's type, while its final field is
the new process domain. The `allow ...:process transition` query above
instead uses the new domain as its target. SELinux-aware programs can also
request an execution context explicitly. The SELinux Notebook explains the
[transition selection and permission checks](https://github.com/SELinuxProject/selinux-notebook/blob/main/src/domain_object_transitions.md).

Together these queries explain the intended policy path; they do not prove
that a particular SSH authentication attempt invoked `unix_chkpwd` or read
the shadow file. That requires separate runtime evidence. The `id` trace
above exercises `id`, not the authentication helper.

## 5. Local wiring — file by file

| File | What it sets |
|---|---|
| `rpi5.yml` | pulls in the `meta-selinux` layer (branch `master`, SHA-pinned) |
| `meta-iot-gateway/conf/distro/include/iotgw-common.inc` | `DISTRO_FEATURES += " selinux"`, `PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"`, `IOTGW_SELINUX_MODE ??= "enforcing"` → `DEFAULT_ENFORCING` |
| `.../recipes-kernel/linux/files/fragments/security-prod.cfg` | the kernel LSM stack (always applied via the `igw_security_prod` feature) |
| `.../recipes-core/packagegroups/packagegroup-iot-gw-selinux.bb` | `packagegroup-core-selinux`, `refpolicy-mcs`, `iotgw-selinux-relabel` |
| `.../recipes-core/images/iot-gw-image-base.inc` | installs that packagegroup + `IMAGE_CLASSES += "selinux-image"` (build-time labelling) |
| `.../recipes-security/refpolicy/refpolicy-mcs_%.bbappend` | adds the `iotgw` module, `file_contexts.subs`/`.local`, the `%sudo`→`staff_u` seusers entry |
| `.../recipes-security/refpolicy/files/policy/iotgw.{te,if,fc}` | project domains, e.g. `rauc_t`, `iotgw_overlay_t`, edge-healthd, the OTBR agent and web UI, the DX-M1 desktop stack |

### 5.1 Kernel — `security-prod.cfg`

```
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_YAMA=y
# CONFIG_SECURITY_APPARMOR is not set
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y     # selinux= on the cmdline (signed into the FIT here)
CONFIG_SECURITY_SELINUX_DEVELOP=y       # runtime setenforce / enforcing= switch (not per-domain permissive)
CONFIG_SECURITY_SELINUX_AVC_STATS=y
CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9
CONFIG_SECURITY_LANDLOCK=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"
```

This fragment is mapped from the `igw_security_prod` kernel feature, which
is in the default `IOTGW_KERNEL_FEATURES` for every image variant, so SELinux is the default MAC everywhere.

### 5.2 Boot activation & enforcing mode

With `CONFIG_DEFAULT_SECURITY_SELINUX=y` and only `selinux` in the
exclusive slot, SELinux activates without needing `security=selinux` on
the cmdline. The **enforcing** default comes from `/etc/selinux/config`
(shipped `SELINUX=enforcing` via `DEFAULT_ENFORCING`), not the cmdline.

The kernel command line is fixed at build time. Runtime root dm-verity bakes
it, verity table included, into the device tree of each signed per-slot FIT,
and U-Boot clears its own `bootargs` so that signed line is what the kernel
receives. Neither the firmware `cmdline.txt` nor `fw_setenv` changes it — so
there is no runtime `selinux=0` / `enforcing=0` switch on any image (see §7).
See `meta-iot-gateway/classes/iotgw-verity-image.bbclass`.

### 5.3 Labelling the writable `/data` partition

The read-only root is labelled at build time by `selinux-image`. `/data` is not
part of the image, so a fresh `/data` is all `unlabeled_t` — including the
sources of the `/data`-backed bind mounts (`/home`, the container store, the
journal, …). Three pieces fix that:

- `file_contexts.subs` (refpolicy-mcs bbappend) aliases each bind source to
  the path it is seen at: `/data/home` → `/home`,
  `/data/machine-id` → `/etc/machine-id`, `/data/log/journal` →
  `/var/log/journal`, and so on. The backing inode then gets exactly the label
  of the path it appears at.
- `file_contexts.local` labels everything else on `/data` `var_lib_t`.
- `iotgw-selinux-relabel.service` runs `restorecon -R -F /data` early in boot
  whenever the policy or file contexts differ from the ones recorded in
  `/data/.iotgw-selinux-labels` (first boot, or an OTA to a slot with a
  different policy), and is a no-op otherwise.

Check a path: `matchpathcon /data/home/devel` (expect `user_home_dir_t`).
A `semodule`/`semanage` transaction on the device regenerates both context
files from the policy store and drops these entries; none runs on this image.

**Never create `/.autorelabel`.** meta-selinux's `selinux-autorelabel` relabels,
deletes the file and reboots. On the read-only dm-verity root it cannot delete
it, so the device would relabel and reboot forever. The build fails if the
rootfs carries one (build-time labelling failure, or `FIRST_BOOT_RELABEL=1`).

## 6. Verifying SELinux on a board

On a running board:

```sh
# Kernel side
zcat /proc/config.gz | grep -E "SECURITY_SELINUX|DEFAULT_SECURITY|CONFIG_LSM"
cat /proc/cmdline

# Userspace side
sestatus                 # mode + policy (mcs) + loaded modules
mount | grep selinuxfs   # /sys/fs/selinux ... selinuxfs
getenforce               # Enforcing
id -Z                    # your own label (not unlabeled_t — build labelled it)

# Audit pipeline
systemctl status auditd
ausearch -m AVC -ts boot | wc -l   # from a sysadm_t shell; staff_t prints <no matches>
systemctl --failed                  # empty
```

`systemd` reports `+SELINUX` when built with libselinux:

```sh
systemctl --version | head -1
systemd --version | grep -o '[-+]SELINUX'
```

## 7. Recovery

### Bad policy blocks something, system still boots
```sh
setenforce 0          # back to permissive; fix policy; setenforce 1
```
This works only from a `sysadm_t` shell (§4.2); from a plain SSH root login
it is refused. A reboot returns to the shipped mode (enforcing); the policy
fix ships in a new bundle.

### Bad policy prevents booting
The kernel command line is signed into the slot FIT (§5.2), so `selinux=0`
cannot be added from `cmdline.txt` or the U-Boot environment. Recovery is the
A/B fallback: a slot that fails to boot exhausts its RAUC boot counter and
U-Boot boots the other slot. Fix the policy and ship it in a new bundle.
There is no `enforcing=0`/`selinux=0` boot path; a second signed FIT
configuration for that is an open item
([SELINUX_ENFORCING.md](SELINUX_ENFORCING.md) §3).

### Labels corrupted or wrong
The root is read-only and labelled at build time; only `/data` can drift.
```sh
rm /data/.iotgw-selinux-labels
systemctl restart iotgw-selinux-relabel.service   # or reboot
```
Do **not** `touch /.autorelabel` (§5.3).

## 8. Runtime trials and diagnostics

How to run a trial safely on a board, diagnose a failure with no denial, and
the remaining open items: [SELINUX_ENFORCING.md](SELINUX_ENFORCING.md).

## 9. References

- [SELinux Project wiki](https://github.com/SELinuxProject/selinux/wiki)
- [The SELinux Notebook](https://github.com/SELinuxProject/selinux-notebook)
- [Reference Policy](https://github.com/SELinuxProject/refpolicy)
- `meta-selinux/README` — layer's own integration notes
- [LSM_IMA_EXPLORATION.md](LSM_IMA_EXPLORATION.md) — IMA and TPM notes
