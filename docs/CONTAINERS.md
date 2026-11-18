# Containers — rootless podman on every image

Every image ships the podman stack (`packagegroup-iot-gw-containers`, no
toggle). Workloads run **rootless**, as one dedicated principal, from Quadlet
units in that principal's systemd user manager. The rootful engine is
installed for administration from a root shell but no unit starts it.

## The principal: `iotgw-ctr`

| Property | Value | Where it is fixed |
|---|---|---|
| uid / gid | 968 / 968 | `meta-iot-gateway/files/iotgw-passwd`, `iotgw-group` (static ids, every image) |
| home | `/home/iotgw-ctr` (0700) — on `/data` through the `/home` bind | `recipes-containers/iotgw-ctr-user` |
| shell | `/sbin/nologin`, locked password, no sudo | same recipe |
| subordinate ids | `iotgw-ctr:200000:65536` in `/etc/subuid` and `/etc/subgid` | `recipes-core/images/iotgw-users.inc` |
| user manager | `user@968.service`, started at boot by `systemd-logind` (linger marker `/var/lib/systemd/linger/iotgw-ctr`) | same recipe |
| Quadlet directory | `/etc/containers/systemd/users/968/` (empty until a workload is added) | same recipe |
| SELinux | login `user_u:user_r`; manager `user_systemd_t`; podman `podman_user_t`; conmon `podman_user_conmon_t`; container `container_t:s0:cX,cY` | `refpolicy/files/policy/iotgw.te` ("Rootless containers") |

The subordinate range and the uid are part of the `/data` format
([PERSISTENT_STATE.md](PERSISTENT_STATE.md)): every file in the store is owned
by 968 or by 200000–265535, and a changed id would orphan the store.

`devel` (dev and desktop images) keeps its own range, `devel:100000:65536`,
and may run rootless containers interactively; it is an admin (`staff_u`),
not the workload principal.

## Engine configuration (`container-host-config`)

| Setting | Value | Why |
|---|---|---|
| storage driver | native kernel `overlay`, `mountopt = "nodev"` | the kernel mounts overlayfs inside a user namespace; no FUSE helper, no device nodes honoured from image layers |
| rootless store | podman default, `~/.local/share/containers/storage` | labelled `container_data_home_t` / `container_ro_file_t` by refpolicy's home-directory contexts; no project file contexts needed |
| `image_copy_tmp_dir` | `storage` (`<graphroot>/tmp`, shipped with the home) | `/var/tmp` is a tmpfs here; a pull would stage layers in RAM |
| rootless network | `pasta` (package `passt`); `slirp4netns` is not installed | runs as the principal in the container's namespace, no setuid helper; `tun` is loaded at boot (`modules-load.d`) |
| bridge networks | netavark + aardvark-dns, `firewall_driver = "nftables"` | the kernel is nftables-only |
| seccomp | `/usr/share/containers/seccomp.json` (podman's default profile, shipped from its source) | the syscall allowlist is readable on the device; `Seccomp: 2` on every container process |
| cgroups | `cgroup_manager = "systemd"` through the user manager | delegation via `user@968.service` |
| per-user podman API, auto-update, restart units | disabled for every user (`50-iotgw-podman-user.preset`) | nothing on the image uses the API socket |
| `podman-user-wait-network-online.service` | no-op drop-in | it polls the system `network-online.target` from a user service, up to 90 s; that target is a trivial sync point here |

Rootful: `podman.service`/`podman.socket` are shipped disabled
(`SYSTEMD_AUTO_ENABLE = "disable"`), nothing wants them, there is no
`/var/lib/containers` bind. `podman` from a root shell (`sysadm_t`) works for
one-off administration and keeps nothing across a reboot (`/var/lib` is
volatile).

## Adding a workload

Drop a Quadlet file into the principal's directory, from a recipe:

```bitbake
do_install() {
    install -d ${D}${sysconfdir}/containers/systemd/users/968
    install -m 0644 ${UNPACKDIR}/myapp.container \
        ${D}${sysconfdir}/containers/systemd/users/968/myapp.container
}
RDEPENDS:${PN} = "iotgw-ctr-user"
```

```ini
# myapp.container
[Container]
Image=registry.example.com/myapp:1.2
Pull=missing
# PublishPort=8080:8080   # host bind by pasta as iotgw-ctr: needs an
                          # explicit family-scoped accept rule in
                          # nftables.conf; ports below 1024 need
                          # net.ipv4.ip_unprivileged_port_start lowered

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

The generator (`podman-user-generator`) turns it into `myapp.service` in the
principal's manager at boot. Images are pulled by the unit (`Pull=missing`)
into the principal's store; an offline device gets them with `podman load`
run as the principal, or from a `.image` Quadlet unit.

What a Quadlet unit cannot do here: anything that needs root on the host
(privileged containers, host devices without a group the principal is in,
ports below 1024 without the sysctl). Device access follows the pattern of
udev rules granting a group plus `IOTGW_ROOTFS_SUPPLEMENTARY_GROUPS` for the
principal; none ships today.

## SELinux

refpolicy wires the rootless podman role for `staff_r` only; `iotgw.te` adds
the same wiring for `user_r`, keyed on `user_application_exec_domain`, which
the user manager domain (`user_systemd_t`) belongs to. Expected chain under
enforcing:

```
systemd-logind -> user@968.service      user_u:user_r:user_systemd_t:s0
  -> podman (Quadlet unit)               user_u:user_r:podman_user_t:s0
     -> conmon                           user_u:user_r:podman_user_conmon_t:s0
        -> crun -> container process     system_u:system_r:container_t:s0:cX,cY
     -> pasta                            podman_user_t (no transition)
```

The engine's exec of the container changes SELinux user and role: refpolicy's
engine domains carry the identity/role change exemptions and `container_t`
is a change target, and the MCS constraints bind only the containers
themselves, so the principal's `s0` range is no obstacle. Every `user_u`
login gains the podman role with this wiring; on these images that is the
principal and non-admin accounts.

## Checking a board

```bash
cat scripts/lib/target-check.sh scripts/containers/rootless-acceptance-target.sh | ssh <gw> 'sudo bash -s'
```

The script asserts the table above, starts a transient Quadlet payload
through the principal's manager (image pulled, or loaded from
`IOTGW_CTR_TEST_IMAGE_TAR`), checks the host uid, `uid_map`, `Seccomp: 2`,
pasta, the domains, store ownership and labels, and counts AVC denials
(needs `sysadm_t`: run it from the serial console for that section), then
removes the payload. Engine and kernel prerequisites:
`scripts/containers/rootless-acceptance-target.sh`.

## Upgrade note

Images before this layout ran a rootful engine with its store on
`/data/containers`. Nothing migrates images from it; the directory can be
deleted by hand on a device that no longer needs an older slot
([PERSISTENT_STATE.md](PERSISTENT_STATE.md) §Upgrade contract).

## Network reach and confinement

Containers reach the network through `pasta`, which runs as the principal and
proxies their connections, so they can open outbound TCP to any port and be
published on any port. They cannot reach the gateway itself. nftables rules in
the output chain, also present in the fallback ruleset, match the principal and
its subordinate uid range and drop:

- new connections over `lo`, which covers every local IPv4 and IPv6 address and
  the `host.containers.internal` mapping, except DNS to the local resolver on
  `127.0.0.53` and `127.0.0.54`;
- IPv4 multicast and broadcast and IPv6 multicast, which would otherwise loop
  back to local listeners such as the mDNS responder.

A workload that must talk to a service on the gateway needs that service exposed
deliberately. Published ports are unaffected, because the forward into the
container happens inside its namespace; publish on `127.0.0.1` unless the
workload is meant for the LAN. Refused traffic is dropped, not rejected, because
the kernel carries no nftables reject, so a client sees a timeout.

`--privileged` and `--security-opt label=disable` are refused for rootless
engines. A local refpolicy patch removes `spc_user_t` from their reach and stops
the engine from executing, without a domain transition, any file type it can
write. A container started without a label, or with `--pid=host`, fails to start
instead of running in the engine's domain.

Named volumes shared with another container, or written by a setup container,
need the `:Z` option, or the categories differ and SELinux refuses the access.

Quadlet files can live in `~/.config/containers/systemd` for workloads managed
on the device, or be shipped by a recipe in `/etc/containers/systemd/users/968`
for platform services. Files in the first path survive OTA and slot switches;
the generator may traverse `~/.config/containers` but not read its contents,
which include registry credentials.

### Limits and accepted trade-offs

The boundary is drawn around the payload. A compromised container process
cannot choose engine options; whoever writes a Quadlet file can.

Options the engine still accepts, most significant first. The container stays in
`container_t` in every case:

| Option | Effect |
|---|---|
| `--cap-add=all`, `seccomp=unconfined`, `no-new-privileges=false` | Widens the kernel attack surface available to the payload |
| Bind mounts of host paths, `--userns=host` | Limited by file modes and by what `container_t` may read; readable host files such as `/etc` are exposed |
| `label=level:s0:c0.c1023` | Removes category separation from other containers of the principal |

The engine domain has weaker limits than the payload:

- `podman_user_t` and conmon are not bound by the MCS constraints.
- `pasta` runs in `podman_user_t` and parses frames sent by the payload. A flaw
  there reaches the engine's authority, including every option above, and a
  transient unit from the user manager runs in `user_t`.
- The engine can still run root filesystem binaries in its own domain, for
  example with `--rootfs /`. Those binaries are covered by dm-verity and are not
  content a payload can supply.

Other limits:

- Outbound LAN and internet access is unrestricted. Filter it upstream if a
  workload should not have it.
- The firewall rules name only the container principal. Containers run by
  another account, such as `devel` on a development image, are not covered.
- `--network host` does not start by default, because crun cannot read
  `/sys/fs/selinux`. Unmasking that path starts it, and the firewall rules still
  apply to the principal's subordinate uids.
- `--init` fails, because the engine may not mount over `bin_t`.
- `podman build` steps that run commands fail, because they need read access to
  the SELinux class files. Build images off the device.
- Multicast and broadcast sent from a container are dropped, so discovery
  protocols do not work from a default network.
- Overlay directory renames are unavailable, because `redirect_dir` stays off.
  The policy store consequence is in [SELINUX_ENFORCING.md](SELINUX_ENFORCING.md) §1.
