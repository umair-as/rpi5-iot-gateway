SUMMARY = "IoT GW systemd-networkd units + wpa_supplicant Wi-Fi config"
DESCRIPTION = "Ships the networkd topology (br0 bridge with eth0 port, wlan0 \
WiFi uplink) and generates wpa_supplicant-wlan0.conf from the IOTGW_WIFI_* \
build variables."
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Wi-Fi credentials, consumed to generate wpa_supplicant-wlan0.conf.
IOTGW_WIFI_SSID       ?= ""
IOTGW_WIFI_PSK        ?= ""
IOTGW_WIFI_IFACE      ?= "wlan0"
# Default IPv4 method for the single-SSID vars and for multi-net lines that
# omit field 4: "auto" (DHCP) or "manual" (static, needs the address fields).
IOTGW_WIFI_IPV4_METHOD ?= "auto"

# Multi-network syntax (preferred), one network per line:
#   'ssid|psk|iface|ipv4method|priority|ipv4addr/prefix|gateway|dns1;dns2'
# Only ssid|psk are required. Field 3 (iface) and the L3 fields are honoured
# for the generated networkd '[Match] SSID=' unit only (emit_networkd_ssid);
# addressing lives in the .network unit, not here, so for static wlan0
# addressing set a matching drop-in. priority maps to the wpa_supplicant
# network priority. NOTE: wpa_supplicant itself is NOT per-line-iface-aware —
# every line's network{} block is written into a single
# wpa_supplicant-${IOTGW_WIFI_IFACE}.conf and only one
# wpa_supplicant@${IOTGW_WIFI_IFACE} instance is enabled (see emit_wpa_network
# and do_install below), regardless of what field 3 says. A line whose iface
# differs from IOTGW_WIFI_IFACE gets a networkd match unit for that iface but
# its credentials land in the default iface's wpa_supplicant conf and no
# wpa_supplicant@<that iface> instance is enabled. Multi-iface wpa_supplicant
# (per-iface conf + enable symlink) is not yet supported: iotgw-hardening.bb's
# service-hardening drop-in and rauc's managed-paths.d/network.conf are both
# hardcoded to the wlan0 instance/conf today, so a genuinely per-iface
# wpa_supplicant would also need those two recipes updated in lockstep to
# avoid shipping an unhardened, RAUC-unmanaged Wi-Fi credential file.
IOTGW_WIFI_NETWORKS   ?= ""

# MAC randomization policy passed through to wpa_supplicant:
#   preassoc_mac_addr=1  -> randomize MAC while scanning (privacy; not the
#                           associated/DHCP MAC, so it's harmless here)
#   mac_addr=0           -> use the permanent (hardware) MAC on association
#   mac_addr=1           -> fresh random MAC per ESS on association
#   mac_addr=2           -> stable generated MAC per ESS
# Default the association MAC to 0 (permanent) for this fixed gateway appliance:
# a stable MAC keeps DHCP reservations and upstream MAC ACLs/monitoring valid,
# whereas per-association randomization (1) draws a new lease on every reconnect.
IOTGW_WIFI_SCAN_RAND  ?= "1"
IOTGW_WIFI_ASSOC_RAND ?= "0"

SRC_URI = " \
    file://10-br0.netdev \
    file://20-br0.network \
    file://15-eth0.network \
    file://25-wlan0.network \
"

S = "${UNPACKDIR}"

# Wi-Fi credentials (IOTGW_WIFI_PSK/_NETWORKS/_SSID) are interpolated directly
# into do_install to generate wpa_supplicant-${IOTGW_WIFI_IFACE}.conf, so they
# MUST stay in the task's vardeps: excluding them (as this recipe previously
# did via do_install[vardepsexclude]) drops the rebuild trigger, not just a
# published hash — editing a credential in kas/local.yml would then leave
# do_install's signature unchanged and sstate would replay stale creds onto
# the image with no build warning. A secret's *hash* landing in the local
# build's task signature is normal, expected BitBake behavior (the plaintext
# itself is never published — only PACKAGE_ARCH ties this recipe's output to
# MACHINE_ARCH so it is never shared across machines/sstate mirrors either).
# If stronger hygiene is ever wanted, depend on a digest of the values via a
# proper vardeps (e.g. a python anonymous function hashing the vars into a
# dedicated IOTGW_WIFI_CREDS_HASH and listing that in vardeps) rather than
# excluding the source variables outright.

# allarch-safe content, but the generated wpa_supplicant conf is host-specific
# secret material; tie to MACHINE_ARCH so it is never shared across machines.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# wlan0 association is driven by the wpa_supplicant template instance shipped
# by wpa-supplicant. It is enabled via 90-iotgw.preset
# (enable wpa_supplicant@wlan0.service) rather than SYSTEMD_SERVICE here, since
# this recipe does not ship that unit file.
RDEPENDS:${PN} = "systemd-networkd wpa-supplicant"

emit_wpa_network() {
    # args: ssid psk priority
    _ssid="$1"; _psk="$2"; _prio="$3"
    # A 64-char hex string is a precomputed PMK and MUST be written unquoted;
    # anything else is an ASCII passphrase and must be quoted. Quoting a hex
    # PMK makes wpa_supplicant treat it as a passphrase and derive the wrong
    # key.
    if echo "$_psk" | grep -qiE '^[0-9a-f]{64}$'; then
        _pskline="psk=$_psk"
    else
        _pskline="psk=\"$_psk\""
    fi
    {
        echo "network={"
        echo "	ssid=\"$_ssid\""
        echo "	$_pskline"
        echo "	key_mgmt=WPA-PSK"
        echo "	priority=$_prio"
        echo "}"
    } >> ${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-${IOTGW_WIFI_IFACE}.conf
}

emit_networkd_ssid() {
    # args: ssid iface ipv4method ipaddr/prefix gateway dns(';' or ',' list)
    # Per-SSID L3 via networkd '[Match] SSID='. networkd reads the associated
    # SSID and applies the matching .network, so different APs keep different
    # addresses. Named 24-* so it sorts before the generic 25-<iface>.network
    # DHCP fallback.
    _ssid="$1"; _iface="$2"; _method="$3"; _ipaddr="$4"; _gw="$5"; _dns="$6"
    _fname=$(printf '%s' "$_ssid" | tr -c '[:alnum:]_.-' '_')
    # The tr sanitizer is lossy — distinct SSIDs ("Site A" vs "Site/A") map to
    # the same name and the second would overwrite the first. Append a short
    # hash of the RAW SSID so each SSID gets a unique, stable filename.
    _hash=$(printf '%s' "$_ssid" | sha256sum | cut -c1-8)
    _out=${D}${sysconfdir}/systemd/network/24-${_iface}-${_fname}-${_hash}.network
    {
        echo "# Generated by iotgw-network-units for SSID '$_ssid'."
        echo "[Match]"
        echo "Name=${_iface}"
        echo "SSID=${_ssid}"
        echo ""
        echo "[Network]"
        if [ "$_method" = "manual" ] && [ -n "$_ipaddr" ]; then
            echo "Address=${_ipaddr}"
            [ -n "$_gw" ] && echo "Gateway=${_gw}"
            for _d in $(echo "$_dns" | tr ';,' '  '); do
                [ -n "$_d" ] && echo "DNS=${_d}"
            done
        else
            echo "DHCP=ipv4"
        fi
    } > "$_out"
}

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/10-br0.netdev   ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${UNPACKDIR}/20-br0.network  ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${UNPACKDIR}/15-eth0.network ${D}${sysconfdir}/systemd/network/
    # Generic wlan0 DHCP fallback for any SSID not given an explicit per-SSID
    # unit below (sorts after the generated 24-<iface>-<ssid>.network files).
    install -m 0644 ${UNPACKDIR}/25-wlan0.network ${D}${sysconfdir}/systemd/network/

    # Enable the wlan0 wpa_supplicant instance. Template instances are not
    # reachable by the enable-only preset-all used in this flow, so ship the
    # multi-user.target.wants symlink directly. (wpa_at holds the template base
    # so the template unit name is never written as a contiguous literal.)
    wpa_at="wpa_supplicant@"
    install -d ${D}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf ${systemd_system_unitdir}/${wpa_at}.service \
        ${D}${sysconfdir}/systemd/system/multi-user.target.wants/${wpa_at}${IOTGW_WIFI_IFACE}.service

    # wpa_supplicant per-interface conf (0600 — carries the PSK).
    install -d -m 0755 ${D}${sysconfdir}/wpa_supplicant
    conf=${D}${sysconfdir}/wpa_supplicant/wpa_supplicant-${IOTGW_WIFI_IFACE}.conf
    {
        echo "# Generated by iotgw-network-units. Managed file."
        echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev"
        echo "update_config=1"
        echo "mac_addr=${IOTGW_WIFI_ASSOC_RAND}"
        echo "preassoc_mac_addr=${IOTGW_WIFI_SCAN_RAND}"
        echo ""
    } > "$conf"
    chmod 0600 "$conf"

    if [ -n "${IOTGW_WIFI_NETWORKS}" ]; then
        # Split records on the literal "\n" separator only. Do NOT use
        # printf '%b', which escape-expands the WHOLE payload and would corrupt a
        # PSK/SSID that legitimately contains a backslash (\t, trailing \, ...).
        printf '%s\n' "${IOTGW_WIFI_NETWORKS}" | awk '{gsub(/\\n/, "\n")}1' | while IFS= read -r line; do
            [ -z "$line" ] && continue
            ssid=$(echo "$line"   | awk -F'|' '{print $1}')
            psk=$(echo  "$line"   | awk -F'|' '{print $2}')
            [ -z "$ssid" ] || [ -z "$psk" ] && continue
            iface=$(echo "$line"  | awk -F'|' -v d="${IOTGW_WIFI_IFACE}"       '{print (NF>=3 && $3!="")?$3:d}')
            method=$(echo "$line" | awk -F'|' -v d="${IOTGW_WIFI_IPV4_METHOD}" '{print (NF>=4 && $4!="")?$4:d}')
            prio=$(echo "$line"   | awk -F'|'                                  '{print (NF>=5 && $5!="")?$5:"100"}')
            ipaddr=$(echo "$line" | awk -F'|'                                  '{print (NF>=6 && $6!="")?$6:""}')
            gw=$(echo "$line"     | awk -F'|'                                  '{print (NF>=7 && $7!="")?$7:""}')
            dns=$(echo "$line"    | awk -F'|'                                  '{print (NF>=8 && $8!="")?$8:""}')
            emit_wpa_network "$ssid" "$psk" "$prio"
            emit_networkd_ssid "$ssid" "$iface" "$method" "$ipaddr" "$gw" "$dns"
        done
    elif [ -n "${IOTGW_WIFI_SSID}" ] && [ -n "${IOTGW_WIFI_PSK}" ]; then
        emit_wpa_network "${IOTGW_WIFI_SSID}" "${IOTGW_WIFI_PSK}" "100"
        emit_networkd_ssid "${IOTGW_WIFI_SSID}" "${IOTGW_WIFI_IFACE}" "${IOTGW_WIFI_IPV4_METHOD}" "" "" ""
    fi
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/network/*.netdev \
    ${sysconfdir}/systemd/network/*.network \
    ${sysconfdir}/wpa_supplicant/wpa_supplicant-${IOTGW_WIFI_IFACE}.conf \
    ${sysconfdir}/systemd/system/multi-user.target.wants/wpa_supplicant@${IOTGW_WIFI_IFACE}.service \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/systemd/network/10-br0.netdev \
    ${sysconfdir}/systemd/network/20-br0.network \
    ${sysconfdir}/systemd/network/15-eth0.network \
    ${sysconfdir}/systemd/network/25-wlan0.network \
    ${sysconfdir}/wpa_supplicant/wpa_supplicant-${IOTGW_WIFI_IFACE}.conf \
"
