# SELinux on the RPi5 IoT Gateway — a 101 plus the local wiring

This is the working-knowledge primer for anyone who maintains, debugs, or
flips the SELinux posture on this distro. It assumes you've used Linux but
not SELinux. The first half explains the concepts; the second half maps
them to the exact files in this tree.

SELinux is the distro's **active MAC**, always on, running **permissive**
by default (denials logged, nothing blocked) until policy coverage is
validated against the full image surface. AppArmor is not carried.

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
| Files on disk | extended attribute `security.selinux` (xattr). Set at build time by `selinux-image.bbclass`, or at first boot by `selinux-autorelabel`, or any time by `restorecon -R /` |
| Processes | Inherited from parent, OR set by a `type_transition` rule when an executable runs |
| Sockets, IPC, /proc, /sys | Computed per-call by policy |

### 2.4 Operating modes

| Mode | LSM hooks called? | Denials enforced? | Denials logged? |
|---|---|---|---|
| Disabled | no | no | no |
| Permissive | yes | **no** | **yes** (to audit) |
| Enforcing | yes | yes | yes |

Switching:
- Kernel cmdline: `selinux=0` (disabled), `enforcing=0` / `enforcing=1`
- Runtime: `setenforce 0|1` (permissive <-> enforcing only — can't go back
  to disabled without reboot)
- The boot default comes from `/etc/selinux/config` (`SELINUX=permissive`),
  which refpolicy ships from `DEFAULT_ENFORCING` in `iotgw-common.inc`.

**The bring-up loop** is: boot permissive -> run real workload -> collect
AVC denials with `ausearch` -> write/audit2allow policy modules to cover
legitimate operations -> repeat until denials stop -> flip to enforcing.

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
  first boot when `/.autorelabel` exists, then deletes the marker.

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

# Re-apply labels
restorecon -Rv /var/log              # relabel a tree
touch /.autorelabel ; reboot         # forced full relabel on next boot

# Inspect / change file contexts
semanage fcontext -a -t var_log_t '/data/log(/.*)?'   # add a rule
restorecon -Rv /data/log                              # apply it

# Per-domain permissive (needs CONFIG_SECURITY_SELINUX_DEVELOP=y — set here)
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

## 5. Local wiring — file by file

| File | What it sets |
|---|---|
| `rpi5.yml` | pulls in the `meta-selinux` layer (branch `scarthgap`) |
| `meta-iot-gateway/conf/distro/include/iotgw-common.inc` | `DISTRO_FEATURES += " selinux"`, `PREFERRED_PROVIDER_virtual/refpolicy = "refpolicy-mcs"`, `DEFAULT_ENFORCING = "permissive"` |
| `.../recipes-kernel/linux/files/fragments/security-prod.cfg` | the kernel LSM stack (always applied via the `igw_security_prod` feature) |
| `.../recipes-core/packagegroups/packagegroup-iot-gw-selinux.bb` | `packagegroup-core-selinux`, `refpolicy-mcs`, `selinux-autorelabel` |
| `.../recipes-core/images/iot-gw-image-base.inc` | installs that packagegroup + `IMAGE_CLASSES += "selinux-image"` (build-time labelling) |

### 5.1 Kernel — `security-prod.cfg`

```
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_YAMA=y
# CONFIG_SECURITY_APPARMOR is not set
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y     # selinux=0 escape on cmdline
CONFIG_SECURITY_SELINUX_DEVELOP=y       # per-domain permissive during bring-up
CONFIG_SECURITY_SELINUX_AVC_STATS=y
CONFIG_SECURITY_SELINUX_SIDTAB_HASH_BITS=9
CONFIG_SECURITY_LANDLOCK=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="lockdown,yama,bpf,landlock,selinux"
```

This fragment is mapped from the `igw_security_prod` kernel feature, which
is in the default `IOTGW_KERNEL_FEATURES` for every image variant
(including the recovery kernel), so SELinux is the default MAC everywhere.

### 5.2 Boot activation & enforcing mode

With `CONFIG_DEFAULT_SECURITY_SELINUX=y` and only `selinux` in the
exclusive slot, SELinux activates without needing `security=selinux` on
the cmdline. The **enforcing** default comes from `/etc/selinux/config`
(shipped `SELINUX=permissive` via `DEFAULT_ENFORCING`), not the cmdline —
so the locked prod kernel cmdline stays untouched.

The RPi5 base kernel cmdline is the firmware `cmdline.txt` baseline plus
whatever U-Boot appends. Runtime cmdline injection (`IOTGW_UBOOT_EXTRA_KERNEL_ARGS`
via `fw_setenv`) is dev-only and rejected by the prod `appliance_lockdown`
env writeable-list — so `selinux=0` recovery on a locked prod board is a
firmware-cmdline / serial-console action, not a runtime one. See
[OPERATIONS.md](OPERATIONS.md) and [UBOOT_HARDENING.md](UBOOT_HARDENING.md).

## 6. Verifying after the rebuild

On the live board, after flashing the new image:

```sh
# Kernel side
zcat /proc/config.gz | grep -E "SECURITY_SELINUX|DEFAULT_SECURITY|CONFIG_LSM"
cat /proc/cmdline

# Userspace side
sestatus                 # mode + policy (mcs) + loaded modules
mount | grep selinuxfs   # /sys/fs/selinux ... selinuxfs
getenforce               # Permissive
id -Z                    # your own label (not unlabeled_t — build labelled it)

# Audit pipeline
systemctl status auditd
ausearch -m AVC -ts boot | wc -l   # >0 expected; permissive logs denials
systemctl --failed                  # empty (everything still works)
```

`systemd` should now report `+SELINUX` (it was `-SELINUX` before, when
libselinux wasn't linked):

```sh
systemctl --version | head -1
systemd --version | grep -o '[-+]SELINUX'
```

## 7. Recovery

### Bad policy blocks something, system still boots
```sh
setenforce 0          # back to permissive; fix policy; setenforce 1
```

### Bad policy prevents booting
Append `selinux=0` to the kernel cmdline for a single boot (via the serial
console / U-Boot, or the firmware `cmdline.txt` on the boot partition).
This disables SELinux for that boot only. Investigate, regenerate policy,
drop `selinux=0`, reboot.

### Labels corrupted or wrong
```sh
touch /.autorelabel
reboot                # selinux-autorelabel runs restorecon -R / on next boot
```

## 8. Roadmap — getting to enforcing

- **RAUC OTA slots:** the bundled rootfs is built with `selinux-image`, so
  OTA-installed slots inherit labels. If a future policy/label change needs
  a relabel on the freshly-written slot, add a RAUC post-install hook that
  `touch`es `/.autorelabel` on the slot mount.
- **Flip to enforcing:** once AVC denials are quiet across the full image
  surface under real workload, set `DEFAULT_ENFORCING = "enforcing"` (or a
  per-tier override so prod enforces while dev stays permissive).
- **Drop the dev escape hatch in prod:** remove
  `CONFIG_SECURITY_SELINUX_DEVELOP=y` from the prod kernel path to close the
  per-domain permissive override surface.
- **Custom policy modules** for this distro's own daemons (iotgw-provision,
  iotgw-banner, ota-updater, ...) as their domains stabilize.

## 9. References

- [SELinux Project wiki](https://github.com/SELinuxProject/selinux/wiki)
- [The SELinux Notebook](https://github.com/SELinuxProject/selinux-notebook)
- [Reference Policy](https://github.com/SELinuxProject/refpolicy)
- `meta-selinux/README` — layer's own integration notes
- [LSM_IMA_EXPLORATION.md](LSM_IMA_EXPLORATION.md) — historical bring-up
  notes from the AppArmor-default era (superseded by this document)
