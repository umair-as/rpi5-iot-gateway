# OTA /etc Overlay Reconciliation Test Plan

This runbook validates update-scoped `/etc` overlay reconciliation executed in
RAUC slot hooks (`pre-install` + `post-install`).

## Scope

Managed files are listed in:

- `/usr/share/iotgw/overlay-reconcile/managed-paths.conf`

Default entries:

- `/etc/nftables.conf`
- `/etc/default/otbr-web`
- `/etc/version`

Format:

```text
<policy> <absolute /etc path>
```

Policies:

- `enforce`
- `replace_if_unmodified`
- `preserve`

## Behavior Model

- `pre-install`: records transaction metadata under `/data/iotgw/overlay-reconcile/txn.json`.
- `post-install`: applies reconciliation using manifests from the newly written target slot.
- It updates `/data/overlays/etc/upper` for the target slot transition.
- No perpetual runtime/boot service loop is used.

## Pre-Update Checks (on target)

```bash
findmnt -no TARGET,FSTYPE,OPTIONS /etc /data
cat /etc/default/otbr-web
grep -n 'dport 80\|dport 443\|dport 8081' /etc/nftables.conf || true
cat /etc/version
```

## Trigger OTA Install

```bash
rauc install <bundle>.raucb
```

Check hook logs:

```bash
journalctl -u rauc.service -b --no-pager | grep -E "bundle-hook|overlay-reconcile"
```

Expected during install:

- `pre-install plan recorded`
- `overlay reconciliation complete: removed=<N>, preserved=<N>, missing=<N>`

## Validate Reconciliation Artifacts

```bash
ls -l /data/iotgw/overlay-reconcile/
cat /data/iotgw/overlay-reconcile/state.tsv
cat /data/iotgw/overlay-reconcile/txn.json
find /data/iotgw/overlay-reconcile/backups -maxdepth 3 -type f | tail -n 20
```

## Post-Reboot Validation

```bash
reboot
# after reconnect:
cat /etc/default/otbr-web
grep -n 'dport 80\|dport 443\|dport 8081' /etc/nftables.conf
cat /etc/version
ss -lntp | grep ':80'
nft list ruleset | sed -n '1,140p'
```

Expected:

- Stale shadowing entries are removed from `/data/overlays/etc/upper` per policy.
- `otbr-web` binds `0.0.0.0:80` (when OTBR enabled).
- nftables contains expected OTBR ports when enabled.
