SUMMARY = "IoT GW native observability meta package"
DESCRIPTION = "Installs native observability components (InfluxDB 1.x + Telegraf) and default runtime settings."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://iotgw-observability.env \
"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/iotgw-observability.env ${D}${sysconfdir}/default/iotgw-observability

    # systemd LoadCredential source files (intentionally empty defaults)
    install -d -m 0700 ${D}${sysconfdir}/credstore
    install -m 0600 /dev/null ${D}${sysconfdir}/credstore/telegraf.service.mqtt_username
    install -m 0600 /dev/null ${D}${sysconfdir}/credstore/telegraf.service.mqtt_password
    install -m 0600 /dev/null ${D}${sysconfdir}/credstore/telegraf.service.influxdb_username
    install -m 0600 /dev/null ${D}${sysconfdir}/credstore/telegraf.service.influxdb_password
}

FILES:${PN} = " \
    ${sysconfdir}/default/iotgw-observability \
    ${sysconfdir}/credstore/telegraf.service.mqtt_username \
    ${sysconfdir}/credstore/telegraf.service.mqtt_password \
    ${sysconfdir}/credstore/telegraf.service.influxdb_username \
    ${sysconfdir}/credstore/telegraf.service.influxdb_password \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/default/iotgw-observability \
    ${sysconfdir}/credstore/telegraf.service.mqtt_username \
    ${sysconfdir}/credstore/telegraf.service.mqtt_password \
    ${sysconfdir}/credstore/telegraf.service.influxdb_username \
    ${sysconfdir}/credstore/telegraf.service.influxdb_password \
"

ALLOW_EMPTY:${PN} = "1"
IOTGW_OBSERVABILITY_ENABLE_INFLUXDB3_NATIVE ?= "0"

RDEPENDS:${PN} = " \
    influxdb \
    telegraf \
"
RDEPENDS:${PN}:append = "${@bb.utils.contains('IOTGW_OBSERVABILITY_ENABLE_INFLUXDB3_NATIVE','1',' influxdb3-bin','',d)}"
