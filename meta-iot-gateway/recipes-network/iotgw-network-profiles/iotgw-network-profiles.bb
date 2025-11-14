SUMMARY = "IoT GW default NetworkManager profiles (Wi-Fi + bridge) and NM config"
DESCRIPTION = "Stages default NM connection profiles; final placement handled by iotgw-rootfs class."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

IOTGW_WIFI_SSID ?= ""
IOTGW_WIFI_PSK ?= ""
IOTGW_WIFI_IFACE ?= "wlan0"
IOTGW_WIFI_IPV4_METHOD ?= "auto"

# Multi-network syntax (preferred): each line
#   'ssid|psk|iface|ipv4method|priority|ipv4addr/prefix|gateway|dns1;dns2'
# iface/ipv4method/priority are optional (default: ${IOTGW_WIFI_IFACE}, ${IOTGW_WIFI_IPV4_METHOD}, 100)
# If ipv4method is 'manual' and 'ipv4addr/prefix' is provided, the connection includes address1 and optional gateway/dns.
IOTGW_WIFI_NETWORKS ?= ""

# NetworkManager MAC randomization defaults (can be overridden in local.conf)
# Scan MAC randomization is generally on by default in NM; keep explicit here.
IOTGW_NM_SCAN_RAND ?= "yes"
# Per-connection MAC policy for Wi‑Fi: one of 'preserve', 'random', 'stable'
IOTGW_NM_WIFI_CLONED_MAC ?= "stable"

SRC_URI = " \
    file://connections/br0.nmconnection \
    file://connections/eth0-slave-br0.nmconnection \
    file://conf.d/10-wifi-backend.conf \
"

S = "${WORKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
    install -d ${D}${datadir}/iotgw-nm/connections
    install -m 0600 ${WORKDIR}/connections/*.nmconnection ${D}${datadir}/iotgw-nm/connections/
    install -d ${D}${datadir}/iotgw-nm/conf.d
    install -m 0644 ${WORKDIR}/conf.d/*.conf ${D}${datadir}/iotgw-nm/conf.d/

    # Emit a MAC randomization policy drop-in for NetworkManager
    cat > ${D}${datadir}/iotgw-nm/conf.d/20-mac-randomization.conf <<EOF
[device]
wifi.scan-rand-mac-address=${IOTGW_NM_SCAN_RAND}

[connection]
wifi.cloned-mac-address=${IOTGW_NM_WIFI_CLONED_MAC}
EOF

    # If multi-network input is provided, generate one connection per line
    if [ -n "${IOTGW_WIFI_NETWORKS}" ]; then
        # Support \n-escaped lists (set via local.conf) using printf '%b'
        printf '%b' "${IOTGW_WIFI_NETWORKS}\n" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            ssid=$(echo "$line" | awk -F'|' '{print $1}')
            psk=$(echo  "$line" | awk -F'|' '{print $2}')
            [ -z "$ssid" ] || [ -z "$psk" ] && continue
            iface=$(echo "$line" | awk -F'|' '{print (NF>=3 && $3!="")?$3:"${IOTGW_WIFI_IFACE}"}')
            method=$(echo "$line" | awk -F'|' '{print (NF>=4 && $4!="")?$4:"${IOTGW_WIFI_IPV4_METHOD}"}')
            prio=$(echo   "$line" | awk -F'|' '{print (NF>=5 && $5!="")?$5:"100"}')
            ipaddr=$(echo "$line" | awk -F'|' '{print (NF>=6 && $6!="")?$6:""}')
            gw=$(echo     "$line" | awk -F'|' '{print (NF>=7 && $7!="")?$7:""}')
            dnslist=$(echo "$line" | awk -F'|' '{print (NF>=8 && $8!="")?$8:""}')
            fname=$(echo "$ssid" | tr -c '[:alnum:]_.-' '_' )
            {
                echo "[connection]"
                echo "id=WiFi ${ssid}"
                echo "type=wifi"
                echo "interface-name=${iface}"
                echo "autoconnect=true"
                echo "autoconnect-priority=${prio}"
                echo
                echo "[wifi]"
                echo "mode=infrastructure"
                echo "ssid=${ssid}"
                echo
                echo "[wifi-security]"
                echo "key-mgmt=wpa-psk"
                echo "psk=${psk}"
                echo
                echo "[ipv4]"
                echo "method=${method}"
                if [ "${method}" = "manual" ] && [ -n "${ipaddr}" ]; then
                    if [ -n "${gw}" ]; then
                        echo "address1=${ipaddr},${gw}"
                    else
                        echo "address1=${ipaddr}"
                    fi
                    if [ -n "${dnslist}" ]; then
                        dnorm=$(echo "${dnslist}" | tr ',' ';' | tr -s ' ' ';')
                        case "$dnorm" in *';') ;; *) dnorm="${dnorm};" ;; esac
                        echo "dns=${dnorm}"
                    fi
                    echo "never-default=false"
                fi
                echo
                echo "[ipv6]"
                echo "addr-gen-mode=stable-privacy"
                echo "method=auto"
            } > ${D}${datadir}/iotgw-nm/connections/wifi-${fname}.nmconnection
            chmod 0600 ${D}${datadir}/iotgw-nm/connections/wifi-${fname}.nmconnection
        done

    # Else, if single-network variables are set, generate one connection
    elif [ -n "${IOTGW_WIFI_SSID}" ] && [ -n "${IOTGW_WIFI_PSK}" ]; then
        cat > ${D}${datadir}/iotgw-nm/connections/wifi.nmconnection <<EOF
[connection]
id=WiFi ${IOTGW_WIFI_SSID}
type=wifi
interface-name=${IOTGW_WIFI_IFACE}
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=${IOTGW_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${IOTGW_WIFI_PSK}

[ipv4]
method=${IOTGW_WIFI_IPV4_METHOD}

[ipv6]
addr-gen-mode=stable-privacy
method=auto
EOF
        chmod 0600 ${D}${datadir}/iotgw-nm/connections/wifi.nmconnection
    fi
}

FILES:${PN} = "${datadir}/iotgw-nm/connections/*.nmconnection ${datadir}/iotgw-nm/conf.d/*.conf"
