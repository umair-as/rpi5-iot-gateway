SUMMARY = "InfluxDB 3 Core native binary (custom integration)"
DESCRIPTION = "Installs InfluxDB 3 Core binary from a prebuilt archive for native target deployment."
HOMEPAGE = "https://www.influxdata.com/"
LICENSE = "CLOSED"

INFLUXDB3_BIN_SRC_URI ?= ""

python __anonymous() {
    if not d.getVar("INFLUXDB3_BIN_SRC_URI"):
        raise bb.parse.SkipRecipe(
            "influxdb3-bin is disabled by default. Set INFLUXDB3_BIN_SRC_URI to a local or remote archive URI."
        )
}

SRC_URI = "${INFLUXDB3_BIN_SRC_URI}"
S = "${WORKDIR}"

inherit systemd

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "influxdb3.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

do_install() {
    install -d ${D}${bindir}

    # Try common archive layouts; fail explicitly if binary is missing.
    bin="$(find ${WORKDIR} -maxdepth 5 -type f \( -name influxdb3 -o -name influxd3 \) | head -n 1)"
    if [ -z "$bin" ]; then
        bbfatal "Unable to locate influxdb3/influxd3 binary in ${WORKDIR}; check INFLUXDB3_BIN_SRC_URI archive layout"
    fi
    install -m 0755 "$bin" ${D}${bindir}/influxdb3

    install -d ${D}${sysconfdir}/default
    cat > ${D}${sysconfdir}/default/influxdb3 <<'EOF'
INFLUXDB3_HTTP_ADDR=127.0.0.1:8181
INFLUXDB3_DATA_DIR=/var/lib/influxdb3
EOF

    install -d ${D}${systemd_system_unitdir}
    cat > ${D}${systemd_system_unitdir}/influxdb3.service <<'EOF'
[Unit]
Description=InfluxDB 3 Core
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-/etc/default/influxdb3
ExecStart=/usr/bin/influxdb3 serve --node-id iotgw --object-store file --data-dir ${INFLUXDB3_DATA_DIR} --http-bind ${INFLUXDB3_HTTP_ADDR}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

FILES:${PN}:append = " \
    ${bindir}/influxdb3 \
    ${sysconfdir}/default/influxdb3 \
    ${systemd_system_unitdir}/influxdb3.service \
"

CONFFILES:${PN}:append = " ${sysconfdir}/default/influxdb3"
