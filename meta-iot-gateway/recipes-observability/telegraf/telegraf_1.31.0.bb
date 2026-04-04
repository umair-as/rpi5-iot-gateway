SUMMARY = "Telegraf native metrics agent"
DESCRIPTION = "Builds and installs Telegraf as a native systemd service for host-level telemetry collection."
HOMEPAGE = "https://github.com/influxdata/telegraf"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

GO_IMPORT = "github.com/influxdata/telegraf"
PV = "1.31.0"
SRCREV = "fbfaba054e62413b6a0a90372281e687d9ff1238"

SRC_URI = " \
    git://github.com/influxdata/telegraf.git;protocol=https;nobranch=1;destsuffix=${BPN}-${PV}/src/${GO_IMPORT} \
    file://telegraf.service \
    file://telegraf.conf \
    file://telegraf.tmpfiles \
"

S = "${WORKDIR}/${BPN}-${PV}"

inherit go-mod systemd
inherit useradd

GO_INSTALL = "${GO_IMPORT}/cmd/telegraf"

# Telegraf 1.31+ ships empty plugins/*/all/all.go and uses per-plugin
# registration files gated by: //go:build !custom || <category>.<plugin>
# Without the "custom" tag every plugin (300+) is compiled, triggering a
# linker duplicate-symbol error from azure-kusto-go vs gosnowflake.
#
# Tag list validated by custom_builder --dry-run against files/telegraf.conf.
# To add a plugin: append its tag here (e.g. inputs.opcua) and add the
# [[inputs.xxx]] stanza to telegraf.conf.
TELEGRAF_PLUGIN_TAGS = "custom,inputs.cpu,inputs.disk,inputs.internal,inputs.mem,inputs.modbus,inputs.mqtt_consumer,inputs.net,inputs.processes,inputs.system,inputs.temp,outputs.influxdb,parsers.json,secretstores.systemd"

# go.bbclass appends GOBUILDFLAGS directly into the go install invocation.
GOBUILDFLAGS:append = " -tags ${TELEGRAF_PLUGIN_TAGS}"

# Upstream Telegraf builds with CGO_ENABLED=0 (all selected plugins are pure Go).
# go.bbclass appends -buildmode=pie by default; combined with CGO this triggers a
# Go 1.22 generic linker bug (duplicate symbol from antlr4/cel-go, kusto/snowflake,
# etc.) that keeps surfacing across different package pairs. Pure Go + no PIE matches
# upstream's release build and avoids this entirely.
CGO_ENABLED = "0"
GOBUILDFLAGS:remove = "-buildmode=pie"
# go.bbclass passes -linkshared which requires CGO. Clear it for pure-Go build.
GO_LINKSHARED = ""

# go modules are resolved during compile in this recipe path.
do_compile[network] = "1"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "telegraf.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

USERADD_PACKAGES = "${PN}"
GROUPADD_PACKAGES = "${PN}"
# Create deterministic service groups during image build; -f makes reruns idempotent.
GROUPADD_PARAM:${PN} = "-f --system telegraf; -f --system dialout"
# dialout membership gives access to /dev/ttyUSB* for Modbus RTU over RS485.
USERADD_PARAM:${PN} = "--system -d /var/lib/telegraf -m -s /sbin/nologin --gid telegraf --groups dialout telegraf"

do_install:append() {
    install -d ${D}${sysconfdir}/telegraf
    install -m 0644 ${WORKDIR}/telegraf.conf ${D}${sysconfdir}/telegraf/telegraf.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/telegraf.service ${D}${systemd_system_unitdir}/telegraf.service

    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/telegraf.tmpfiles ${D}${nonarch_libdir}/tmpfiles.d/telegraf.conf
}

FILES:${PN}:append = " \
    ${sysconfdir}/telegraf/telegraf.conf \
    ${systemd_system_unitdir}/telegraf.service \
    ${nonarch_libdir}/tmpfiles.d/telegraf.conf \
"

CONFFILES:${PN}:append = " ${sysconfdir}/telegraf/telegraf.conf"

# windows-gen-syso.sh ends up in telegraf-dev (Go source tree) and triggers a
# file-rdeps QA warning for /bin/bash. It's a Windows build helper — skip it.
INSANE_SKIP:telegraf-dev += "file-rdeps"
