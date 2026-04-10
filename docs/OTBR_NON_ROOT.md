# Running OTBR as a Non-Root User

This document describes the requirements and configuration needed to run OpenThread Border Router (OTBR) as a dedicated non-root user (e.g., `otbr`).

Note: examples below show the model and reasoning flow. The current repository
implementation uses a dedicated runtime socket directory (`/run/otbr`) and an
explicit RCP device dependency in `otbr-agent.service`.

## Overview

Running OTBR as a non-root user improves security by following the principle of least privilege. However, OTBR requires several elevated capabilities and permissions to function correctly.

## Required Linux Capabilities

The following capabilities must be granted to the `otbr-agent` process:

| Capability | Required For |
|------------|--------------|
| `CAP_NET_ADMIN` | TUN device creation (`TUNSETIFF` ioctl), netlink socket operations, interface configuration, multicast routing (MRT6_*), netfilter queue, routing table modifications, `SO_BINDTODEVICE` socket option |
| `CAP_NET_RAW` | Raw ICMPv6 sockets (`AF_INET6, SOCK_RAW, IPPROTO_ICMPV6`), IPv6 checksum configuration |
| `CAP_NET_BIND_SERVICE` | Binding to privileged ports if needed (optional, ports used are typically > 1024) |

## Systemd Service Configuration

### Minimal Working Configuration

```ini
[Unit]
Description=OpenThread Border Router Agent
ConditionPathExists=/usr/sbin/otbr-agent
Requires=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device
After=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device

[Service]
User=otbr
Group=otbr
SupplementaryGroups=dialout
EnvironmentFile=-/etc/default/otbr-agent
ExecStartPre=+/usr/libexec/otbr/otbr-ipset-init
ExecStartPre=+/bin/sh -c 'rm -f /run/otbr/openthread-wpan0.sock; touch /run/otbr/openthread-wpan0.lock; chown otbr:otbr /run/otbr/openthread-wpan0.lock; chmod 660 /run/otbr/openthread-wpan0.lock'
ExecStart=/usr/sbin/otbr-agent $OTBR_AGENT_OPTS
KillMode=mixed
Restart=on-failure
RestartSec=5

# Required Capabilities
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

### With Systemd Hardening (Recommended)

```ini
[Unit]
Description=OpenThread Border Router Agent
ConditionPathExists=/usr/sbin/otbr-agent
Requires=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device
After=dbus.socket avahi-daemon.service dev-otbr\x2drcp.device

[Service]
User=otbr
Group=otbr
SupplementaryGroups=dialout
EnvironmentFile=-/etc/default/otbr-agent

# Setup (runs as root due to + prefix)
ExecStartPre=+/usr/libexec/otbr/otbr-ipset-init
ExecStartPre=+/bin/sh -c 'rm -f /run/otbr/openthread-wpan0.sock; touch /run/otbr/openthread-wpan0.lock; chown otbr:otbr /run/otbr/openthread-wpan0.lock; chmod 660 /run/otbr/openthread-wpan0.lock'

ExecStart=/usr/sbin/otbr-agent $OTBR_AGENT_OPTS
KillMode=mixed
Restart=on-failure
RestartSec=5

# Capabilities
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

# Hardening options
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=false          # Must be false for /dev/net/tun access
ProtectKernelTunables=true    # If OTBR needs sysctl changes, set false
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=false

# State directory
StateDirectory=thread
ReadWritePaths=/var/lib/thread
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
```

## DBus Policy Configuration

The `otbr` user must be allowed to own the DBus service name. Update `/etc/dbus-1/system.d/otbr-agent.conf`:

```xml
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
    <policy user="root">
        <allow own_prefix="io.openthread.BorderRouter"/>
        <allow send_interface="io.openthread.BorderRouter"/>
        <allow send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_interface="org.freedesktop.DBus.Introspectable"/>
    </policy>
    <policy user="otbr">
        <allow own_prefix="io.openthread.BorderRouter"/>
        <allow send_interface="io.openthread.BorderRouter"/>
        <allow send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_interface="org.freedesktop.DBus.Introspectable"/>
    </policy>
    <policy group="root">
        <allow send_interface="io.openthread.BorderRouter"/>
        <allow send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_interface="org.freedesktop.DBus.Introspectable"/>
    </policy>
    <policy context="default">
        <allow send_interface="io.openthread.BorderRouter"/>
        <allow send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_interface="org.freedesktop.DBus.Introspectable"/>
    </policy>
</busconfig>
```

After modifying, reload DBus:
```bash
systemctl reload dbus
```

## Unix Socket Permissions

In this project, OTBR uses `/run/otbr` via `OTBR_SOCKET_DIR=/run/otbr`.
Typical runtime files:
- `/run/otbr/openthread-wpan0.sock`
- `/run/otbr/openthread-wpan0.lock`

### Solution 1: tmpfiles.d + socket dir override (Recommended)

If you want a dedicated socket directory (instead of `/run`), set
`OTBR_SOCKET_DIR` and ensure the daemon respects it.
This repository already uses that pattern in the shipped unit.

Create `/usr/lib/tmpfiles.d/otbr.conf`:
```
d /run/otbr 0750 otbr otbr -
```

Set the socket directory in the unit and keep these `ExecStartPre` entries:
```ini
Environment=OTBR_SOCKET_DIR=/run/otbr
ExecStartPre=+/bin/sh -c 'rm -f /run/otbr/openthread-wpan0.sock; touch /run/otbr/openthread-wpan0.lock; chown otbr:otbr /run/otbr/openthread-wpan0.lock; chmod 660 /run/otbr/openthread-wpan0.lock'
ReadWritePaths=/run
```

### Solution 2: ExecStartPre ACL (Alternative)

Grant the `otbr` user write permission to `/run` in the unit:
```ini
ExecStartPre=+/bin/sh -c 'setfacl -m u:otbr:rwx /run'
```

## Device Permissions

### Serial Device (RCP)

The user must have access to the serial device (e.g., `/dev/ttyUSB0` or `/dev/otbr-rcp`):

```bash
# Add user to dialout group
usermod -aG dialout otbr
```

Or create a udev rule `/etc/udev/rules.d/99-otbr-rcp.rules`:
```
SUBSYSTEM=="tty", ATTRS{idVendor}=="XXXX", ATTRS{idProduct}=="YYYY", SYMLINK+="otbr-rcp", GROUP="otbr", MODE="0660"
```

### TUN Device

Access to `/dev/net/tun` is granted via `CAP_NET_ADMIN`. Ensure `PrivateDevices=false` in the systemd service.

## Known Issues and Pending Investigation

### 1. IPv6 Address Addition Warnings

The following warnings appear in logs but don't prevent operation:
```
[W] P-Netif-------: ADD [U] fe80::107f:217:fc6f:63bf failed (InvalidArgs)
[W] P-Netif-------: Failed to process event, error:InvalidArgs
```

**Status**: Needs investigation. May be related to address already existing or netlink message format.

### 2. ProtectKernelTunables Compatibility

Setting `ProtectKernelTunables=true` may cause issues if OTBR needs to modify sysctl settings for IPv6 forwarding. Test with your specific configuration.

### 3. External Command Execution

Some operations in OTBR execute external commands via `system()`:
- `ip -6 route` commands (in `dua_routing_manager.cpp`)
- `ip6tables` commands (in `nd_proxy.cpp`)
- `ipset` commands (firewall management)

These commands require root privileges. The current workaround uses `ExecStartPre=+` to run initialization scripts as root.

**Potential improvement**: Configure sudo rules for specific commands:
```
# /etc/sudoers.d/otbr
otbr ALL=(root) NOPASSWD: /sbin/ip, /usr/sbin/ip6tables, /usr/sbin/ipset
```

### 4. Multicast Routing

Multicast routing operations (`MRT6_INIT`, `MRT6_ADD_MIF`, etc.) require `CAP_NET_ADMIN`, which is included in the configuration.

## Troubleshooting

### Debug with strace

To trace system calls and identify permission issues:
```bash
# Run with capabilities
capsh --user=otbr \
  --inh='cap_net_admin,cap_net_raw,cap_net_bind_service' \
  --addamb='cap_net_admin,cap_net_raw,cap_net_bind_service' \
  -- -c 'strace -f -e trace=socket,bind,ioctl /usr/sbin/otbr-agent [args]'
```

### Check Effective Capabilities

```bash
# For running process
cat /proc/$(pgrep -x otbr-agent)/status | grep Cap

# Decode capabilities
capsh --decode=<hex_value>
```

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `TUNSETIFF: Operation not permitted` | Missing `CAP_NET_ADMIN` | Add to `AmbientCapabilities` |
| `bind: Permission denied` on Unix socket | No write access to `/run/otbr` | Verify runtime dir ownership/permissions (`/run/otbr`) |
| `DBus.Error.AccessDenied: not allowed to own the service` | Missing DBus policy | Update `/etc/dbus-1/system.d/otbr-agent.conf` |
| `Raw socket: Permission denied` | Missing `CAP_NET_RAW` | Add to `AmbientCapabilities` |

## Operations Requiring Root Privileges

The following operations in OTBR code require elevated privileges:

| File | Operation | Privilege Required |
|------|-----------|-------------------|
| `src/host/posix/netif_linux.cpp:96` | Open `/dev/net/tun` | `CAP_NET_ADMIN` |
| `src/host/posix/netif_linux.cpp:99` | `TUNSETIFF` ioctl | `CAP_NET_ADMIN` |
| `src/host/posix/netif.cpp:334` | Raw ICMPv6 socket | `CAP_NET_RAW` |
| `src/host/posix/netif.cpp:348` | `SO_BINDTODEVICE` | `CAP_NET_RAW` |
| `src/host/posix/infra_if.cpp:278` | Raw ICMPv6 socket | `CAP_NET_RAW` |
| `src/host/posix/multicast_routing_manager.cpp:202` | `MRT6_INIT` | `CAP_NET_ADMIN` |
| `src/backbone_router/nd_proxy.cpp:418` | Netfilter queue | `CAP_NET_ADMIN` |
| `src/utils/socket_utils.cpp:65` | Netlink route socket | `CAP_NET_ADMIN` |

## References

- [Linux Capabilities man page](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [systemd.exec documentation](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [DBus policy configuration](https://dbus.freedesktop.org/doc/dbus-daemon.1.html)
