# Build wpa_supplicant from the distro's own configuration instead of upstream's
# everything-on defconfig (see files/iotgw-wpa_supplicant.config for what is left
# out and why). oe-core's do_configure copies the defconfig and sets CONFIG_TLS;
# this replaces that step with the same shape, so PACKAGECONFIG still decides
# the TLS library.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://iotgw-wpa_supplicant.config"

do_configure() {
	${MAKE} -C wpa_supplicant clean
	sed -e '/^CONFIG_TLS=/d' <${UNPACKDIR}/iotgw-wpa_supplicant.config >wpa_supplicant/.config

	if ${@ bb.utils.contains('PACKAGECONFIG', 'openssl', 'true', 'false', d) }; then
		echo 'CONFIG_TLS=openssl' >>wpa_supplicant/.config
	elif ${@ bb.utils.contains('PACKAGECONFIG', 'gnutls', 'true', 'false', d) }; then
		echo 'CONFIG_TLS=gnutls' >>wpa_supplicant/.config
		sed -i -e 's/\(^CONFIG_SAE=\)/#\1/' wpa_supplicant/.config
	fi

	# Guard against the surface creeping back in through a future config edit.
	for opt in CONFIG_WPS CONFIG_P2P CONFIG_AP CONFIG_TDLS CONFIG_HS20 CONFIG_INTERWORKING \
	           CONFIG_DPP CONFIG_WIFI_DISPLAY CONFIG_DRIVER_WEXT CONFIG_MACSEC CONFIG_IBSS_RSN; do
		if grep -q "^${opt}=" wpa_supplicant/.config; then
			bbfatal "iotgw wpa_supplicant config enables ${opt}; the station build must not (see iotgw-wpa_supplicant.config)"
		fi
	done

	# For rebuild
	rm -f wpa_supplicant/*.d wpa_supplicant/dbus/*.d
}
