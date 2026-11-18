# Observability

## Current state

This layer ships two observability surfaces. The defaults reflect the
*current* operating posture, not the layer's full capability:

| Surface | Scope | Default | Notes |
|---------|-------|---------|-------|
| `edge-healthd` | Local unit/mount health, journald-published telemetry | **enabled** in all image variants via `packagegroup-iot-gw-apps`'s `-monitoring` slice | Recipe at `meta-iot-gateway/recipes-support/edge-healthd/`. Monitored services and mounts are configured in `files/healthd.conf`. |
| **Telegraf + InfluxDB stack** (this document) | Host metrics, time-series storage, dashboard-ready | **opt-in**, not in any image variant | Recipes last validated on scarthgap (`recipes-observability/telegraf/`, `recipes-observability/influxdb/`, `recipes-observability/influxdb3-bin/`); revalidate on wrynose when reinstating. See [Reinstatement](#reinstatement) below. |

`edge-healthd` covers the "is anything broken right now" question for the
field. The Telegraf+InfluxDB stack is for richer telemetry — historical
metrics, dashboards, future agentd / fleet-aggregation use cases — and is
the scope of the rest of this document.

## Engineering rationale

Why Telegraf is packaged natively in this layer instead of as a sidecar
container or pulled from an upstream OE layer:

- **No usable upstream OE recipe.** The OE layer index carries Telegraf in
  four layers (`meta-luneos`, `meta-webosose`, `meta-ossystems-base`,
  `meta-influx`); none go above 1.21.4. Telegraf 1.31 changed plugin
  registration to per-plugin files gated by `//go:build !custom ||
  <category>.<plugin>`, so the older recipe structures don't just need a
  version bump — they need a different build model entirely.
- **Minimal plugin set, not the 300+ default.** With the 1.31 build-constraint
  scheme, `telegraf custom_builder --dry-run --config telegraf.conf` from
  the upstream tree emits the exact `-tags` list the configured plugins
  need. The recipe pins that list as `TELEGRAF_PLUGIN_TAGS`. This both
  produces a much smaller binary and sidesteps a Go-linker duplicate-symbol
  error (`__cgoenqueue` defined in both `azure-kusto-go` and `gosnowflake`
  via shared antlr4/cel-go generated C code) that fires the moment all
  plugins are pulled in.
- **Pure-Go build matches upstream's release flags.** `CGO_ENABLED=0`,
  `GOBUILDFLAGS:remove = "-buildmode=pie"`, `GO_LINKSHARED=""`. Mixing
  PIE + CGO under `go.bbclass`'s defaults trips a separate duplicate-symbol
  failure from a different package pair in the same generated-code tree.
  The symptom keeps surfacing from different package combinations until
  the flags match upstream's pure-Go release build.
- **Credentials never in the rootfs or the environment.** The root
  filesystem (ext4 under dm-verity) is replaced wholesale on RAUC OTA, so anything baked into the image is
  either shared fleet-wide or wiped on upgrade. `EnvironmentFile=` exposes
  secrets in `/proc/$PID/environ` and core dumps; `Environment=` in a unit
  drop-in serialises into `/run/systemd/` and is visible via
  `systemctl show`. The stack uses systemd `LoadCredential=` (250+) plus
  Telegraf's `secretstores.systemd` plugin so secrets exist only as files
  in a per-unit tmpfs at `$CREDENTIALS_DIRECTORY`, mode 0500/0400, owned
  by the service user — not in env, not in argv, not in `/proc`. The
  persistent backing for those credentials must live on `/data`, which OTA
  does not touch. `/etc` is a tmpfs-upper overlay rebuilt from the slot on
  every boot, so the credstore has to be repopulated on every boot.
- **Network-online gating is a deliberate choice, not a default.** The
  recipe defaults to local-first ordering (`After=network.target`)
  because telegraf and influxdb both live on `127.0.0.1` in the standard
  topology. Remote DB deployments need the network-online drop-in; see
  [Reinstatement → network-online decision](#network-online-decision).

## Architecture

When the stack is installed, all inter-service traffic stays on
`127.0.0.1`. No port is exposed to external interfaces by default.

```mermaid
flowchart TD
    sysmets(["System metrics\n/proc · /sys · /dev"])

    subgraph gw["IoT Gateway — all inter-service traffic on 127.0.0.1"]
        tele["Telegraf\nmetrics agent"]
        idb[("InfluxDB 1.x\ntime-series DB\n:8086 localhost")]

        tele -- "write" --> idb
    end

    sysmets -- "cpu · mem · disk · temp · net · processes" --> tele
```

## Components

| Component  | Version | Recipe |
|------------|---------|--------|
| Telegraf   | 1.31.0  | `recipes-observability/telegraf/telegraf_1.31.0.bb` |
| InfluxDB 1 | 1.x     | `recipes-observability/influxdb/influxdb_%.bbappend` |
| InfluxDB 3 | 3.0.0   | `recipes-observability/influxdb3-bin/influxdb3-bin_3.0.0.bb` (experimental, see [Upgrading to InfluxDB 3](#upgrading-to-influxdb-3-native)) |

**Persistence.** When the optional InfluxDB 3 recipe is installed, its data
directory persists at `/data/influxdb3` (`INFLUXDB3_DATA_DIR`). See
[Persistent State Architecture](PERSISTENT_STATE.md).

There is no meta-package; reinstatement is done by adding the desired
components directly to `IMAGE_INSTALL`. The credential scaffolding lives in
the Telegraf recipe.

## Reinstatement

### 1. Add to an image

Either in a custom image recipe:

```bitbake
IMAGE_INSTALL:append = " telegraf influxdb"
```

…or in `kas/local.yml`:

```yaml
local_conf_header:
  observability: |
    IMAGE_INSTALL:append = " telegraf influxdb"
```

This pulls in:

- The Telegraf binary, its `telegraf.conf`, the hardened
  `telegraf.service`, the tmpfiles entry, and **the credential
  scaffolding**: `/etc/credstore/` (mode 0700, root:root) with
  zero-byte placeholders (mode 0600, root:root) for
  `telegraf.service.influxdb_{username,password}`, plus
  `/etc/default/iotgw-observability` carrying empty `INFLUXDB_URL` /
  `INFLUXDB_DATABASE` defaults for the integrator to fill.
- InfluxDB 1.x (or InfluxDB 3 via the experimental recipe — see below).

### 2. Wire per-boot credential population

The Telegraf recipe ships a worked example at
`/usr/share/iotgw-observability/provision-credstore.sh.example` that
reads the InfluxDB credentials from an operator-supplied env file on
`/data` (the script's `OBS_SRC`) and populates the credstore files via an
idempotent `set_credential_value` helper. The layer ships no unit that runs
it: integrate it into an image-specific oneshot unit ordered before
`telegraf.service`. Because `/etc` is rebuilt from the slot on every boot,
the unit must run on **every** boot, not only the first.

Bootstrap file format — write this to the `OBS_SRC` path on the device
(mode 0600, root:root):

```sh
INFLUXDB_USERNAME=telegraf
INFLUXDB_PASSWORD=<strong-password>
```

The example script does **not** delete this file after success; that's a
rotation-policy decision left to the integrator. A consume-and-delete
pattern (shred on success) reduces on-disk secret exposure but loses
recovery if a later reprovision is needed before the next manufacturing
event — pick per fleet policy.

Until non-empty values land in the credstore files, telegraf.service
remains in `condition-failed` state thanks to the
`ConditionFileNotEmpty=` directives in `[Unit]`. This is the intended
behaviour — no restart loop, no journal noise, clean recovery on the
next start attempt once provisioning completes.

### 3. Non-secret config

`INFLUXDB_URL` and `INFLUXDB_DATABASE` ship empty so a misconfigured
image fails loudly rather than silently writing to a wrong endpoint.
Set them at build time (kas overlay / local.conf bbappend). `/etc` is reset
from the slot on every boot, so a runtime edit to
`/etc/default/iotgw-observability` does not survive a reboot; persist
runtime values on `/data` and have the provisioning unit apply them.

### Network-online decision

The recipe defaults to **local-first** ordering, matching the
standard `127.0.0.1` topology where telegraf and influxdb both run
locally:

```
TELEGRAF_REQUIRE_NETWORK_ONLINE ?= "0"
```

Flip to `"1"` in a bbappend or `kas/local.yml` to install a systemd
drop-in (`/etc/systemd/system/telegraf.service.d/10-network-online.conf`)
that switches ordering to `network-online.target`.
Recommended only when telegraf's outputs talk to **remote** endpoints
whose DNS / routing isn't ready at `network.target` — the local-DB case
does not benefit.

```yaml
# kas/local.yml
local_conf_header:
  observability_netmode: |
    TELEGRAF_REQUIRE_NETWORK_ONLINE = "1"
```

There is no runtime override surface. An operator who needs runtime mode
switching can write a drop-in under `/run/systemd/system/telegraf.service.d/`
(ephemeral); a persistent change is the build-time
`TELEGRAF_REQUIRE_NETWORK_ONLINE` setting.

## Credential flow

```mermaid
flowchart TD
    env(["env file on /data\noperator-supplied · 0600"])
    prov["image-specific unit, every boot\n(example: provision-credstore.sh.example)"]
    cred["/etc/credstore/\ntelegraf.service.*\nroot:root 0700 · files 0600"]
    sd["systemd\nLoadCredential="]
    run["/run/credentials/telegraf.service/\nper-unit tmpfs · 0500 · telegraf user only"]
    conf["telegraf.conf\nsecretstores.systemd plugin\ncredential refs resolved at runtime"]

    env -->|"read"| prov
    prov -->|"writes"| cred
    cred -->|"at service start"| sd
    sd -->|"bind-mounted into unit"| run
    run -->|"resolved at runtime"| conf
```

Credential references in `telegraf.conf`:

```toml
[[secretstores.systemd]]
  id = "systemd"
  prefix = ""

[[outputs.influxdb]]
  urls = ["${INFLUXDB_URL}"]
  database = "${INFLUXDB_DATABASE}"
  username = "@{systemd:influxdb_username}"
  password = "@{systemd:influxdb_password}"
```

The `@{systemd:key}` references resolve at runtime from
`$CREDENTIALS_DIRECTORY`. `INFLUXDB_URL` and `INFLUXDB_DATABASE` come
from the non-secret env file via `EnvironmentFile=-/etc/default/iotgw-observability`.

## Telegraf inputs

The shipped `telegraf.conf` enables the following inputs, matching the
`TELEGRAF_PLUGIN_TAGS` set in the recipe:

| Plugin | Source | Notes |
|--------|--------|-------|
| `inputs.cpu` | `/proc/stat` | per-core + total |
| `inputs.mem` | `/proc/meminfo` | |
| `inputs.disk` | `statfs` | excludes tmpfs/overlay/squashfs |
| `inputs.system` | `/proc/loadavg` | load average, uptime |
| `inputs.temp` | `/sys/class/thermal` | SoC temperature |
| `inputs.processes` | `/proc` | process state counts |
| `inputs.net` | `/proc/net/dev` | `eth*`, `wlan*` interfaces |
| `inputs.modbus` | disabled | stanzas provided as commented examples |
| `inputs.internal` | Telegraf self | agent metrics |

Adding a plugin requires both a config stanza and a tag in
`TELEGRAF_PLUGIN_TAGS` — re-derive the full tag set with
`telegraf custom_builder --dry-run --config telegraf.conf` from the
upstream tree. Don't guess.

### Adding Modbus devices

Modbus TCP and RTU examples are included as commented stanzas in
`/etc/telegraf/telegraf.conf`. Uncomment and fill in device-specific
addressing. For Modbus RTU over RS485:

```toml
[[inputs.modbus]]
  name = "rs485_sensor"
  slave_id = 1
  timeout = "2s"
  controller = "file:///dev/ttyUSB0"
  baud_rate = 9600
  ...
```

> **Note:** If RS485/Modbus RTU is enabled, remove `PrivateDevices=yes`
> from `telegraf.service` or add an explicit `DeviceAllow=` for
> `/dev/ttyUSB*`. See the comment in the unit.

## Service hardening

When the stack is installed, both services run with systemd security
sandboxing:

| Setting | telegraf | influxdb |
|---------|----------|---------|
| `User=` | `telegraf` | `influxdb` |
| `NoNewPrivileges` | yes | yes |
| `PrivateTmp` | yes | yes |
| `ProtectSystem` | strict | — |
| `CapabilityBoundingSet` | _(empty)_ | — |
| `RestrictAddressFamilies` | `AF_UNIX AF_NETLINK AF_INET AF_INET6` | — |
| `StartLimitIntervalSec` | 5m (burst-limited) | 0 (retry forever) |
| `StartLimitBurst` | 3 | — |
| `RestartSec` | 30s | 10s |

Telegraf startup is gated by `ConditionFileNotEmpty=` directives in
`[Unit]` that require non-empty credstore files. This prevents crash
loops before provisioning has applied credentials.

## OTA behaviour

`/etc` comes from the installed slot on every boot, so config files under
`/etc` (`/etc/default/iotgw-observability`, `/etc/telegraf/telegraf.conf`,
`/etc/influxdb/influxdb.conf`) always match the image; there is nothing to
reconcile. Anything that must survive reboot or OTA (credentials, endpoint
values) lives on `/data` and is copied into `/etc/credstore/` by the
provisioning unit at boot.

## Querying data

InfluxDB 1.x API/CLI requires authentication. Reuse the provisioned
Telegraf credentials for interactive checks:

```sh
INFLUX_USER="$(cat /etc/credstore/telegraf.service.influxdb_username)"
INFLUX_PASS="$(cat /etc/credstore/telegraf.service.influxdb_password)"
```

InfluxDB 1.x HTTP API (from the gateway itself or over SSH tunnel):

```sh
# List measurements
curl -sG 'http://localhost:8086/query' \
  --data-urlencode "db=gateway_data" \
  --data-urlencode "u=${INFLUX_USER}" \
  --data-urlencode "p=${INFLUX_PASS}" \
  --data-urlencode "q=SHOW MEASUREMENTS"

# Last 5 minutes of CPU usage
curl -sG 'http://localhost:8086/query' \
  --data-urlencode "db=gateway_data" \
  --data-urlencode "u=${INFLUX_USER}" \
  --data-urlencode "p=${INFLUX_PASS}" \
  --data-urlencode "q=SELECT mean(usage_system) FROM cpu WHERE time > now()-5m GROUP BY time(1m)"
```

InfluxDB CLI (on target):

```sh
influx -username "${INFLUX_USER}" -password "${INFLUX_PASS}" -database gateway_data
> SHOW MEASUREMENTS
> SELECT * FROM cpu ORDER BY time DESC LIMIT 5
```

## Upgrading to InfluxDB 3 (Native)

An experimental `influxdb3-bin` recipe ships in
`recipes-observability/influxdb3-bin/`. To switch the reinstated stack
from InfluxDB 1.x to InfluxDB 3 Core, add `influxdb3-bin` to
`IMAGE_INSTALL` in place of `influxdb`. The Telegraf output plugin and
query API differ — update `outputs.influxdb` → `outputs.influxdb_v2` in
`telegraf.conf` and adjust the credential set accordingly.

The `INFLUXDB3_BIN_SRC_URI` variable must be set to point at the
prebuilt archive; see the recipe header for details.
