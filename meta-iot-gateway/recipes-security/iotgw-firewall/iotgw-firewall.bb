SUMMARY = "IoT GW nftables baseline rules"
HOMEPAGE = "https://github.com/umair-as/rpi5-iot-gateway"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://nftables.conf \
           file://nftables-otbr.conf \
           file://nftables-otbr-forward.conf \
           file://nftables-otbr-webui.conf \
          "

S = "${UNPACKDIR}"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# The OTBR rules live in their own file rather than inline in a sed script.
# As embedded sed text they were invisible to any grep over *.conf, so a lint or
# guard scanning the tracked ruleset would have passed while the OTBR build
# branch - the one that actually shipped - carried unqualified rules. Keeping
# them in a real file means one pattern covers both build configurations.
do_install() {
    install -d ${D}${datadir}/iotgw-firewall
    install -m 0644 ${UNPACKDIR}/nftables.conf ${D}${datadir}/iotgw-firewall/nftables.conf
    sed -i -e 's/@IOTGW_CTR_UID@/${IOTGW_CTR_UID}/g' \
        -e 's/@IOTGW_CTR_SUBID_RANGE@/${IOTGW_CTR_SUBID_RANGE}/g' \
        ${D}${datadir}/iotgw-firewall/nftables.conf

    if [ "${IOTGW_ENABLE_OTBR}" = "1" ]; then
        # Splice each fragment in at its marker, then drop the marker line
        # itself: the input-chain service rules at @OTBR_RULES@, the
        # Thread <-> infrastructure forwarding pair at @OTBR_FORWARD_RULES@.
        # Expand the fragment FIRST: sed's `r` appends the file after the
        # current cycle, so a substitution in the same invocation never sees
        # the spliced lines, leaving @OTBR_INFRA_IFACE@ unexpanded.
        for frag in otbr otbr-forward; do
            sed -e 's/@OTBR_INFRA_IFACE@/${IOTGW_OTBR_INFRA_IFACE}/g' \
                ${UNPACKDIR}/nftables-${frag}.conf > ${WORKDIR}/nftables-${frag}.expanded
        done
        sed -i -e '/@OTBR_RULES@/r ${WORKDIR}/nftables-otbr.expanded' \
               -e '/@OTBR_RULES@/d' \
               -e '/@OTBR_FORWARD_RULES@/r ${WORKDIR}/nftables-otbr-forward.expanded' \
               -e '/@OTBR_FORWARD_RULES@/d' \
               ${D}${datadir}/iotgw-firewall/nftables.conf
        # The web-UI (:80) rule is decided per image by iotgw-rootfs.bbclass
        # (IOTGW_IMAGE_OTBR_WEBUI); stage it next to the ruleset.
        install -m 0644 ${UNPACKDIR}/nftables-otbr-webui.conf \
            ${D}${datadir}/iotgw-firewall/nftables-otbr-webui.conf
    else
        # No OTBR: no service ports and no forwarding pair; the forward chain
        # is left with its drop policy and the conntrack rules only.
        sed -i -e '/@OTBR_RULES@/d' -e '/@OTBR_FORWARD_RULES@/d' \
            ${D}${datadir}/iotgw-firewall/nftables.conf
    fi

    # Fail the build rather than ship a rule that silently spans both families.
    # Matches tcp/udp dport ANYWHERE on a rule line (not just as the first
    # token, so "ct state new tcp dport 22 accept" is caught too). Comments
    # are stripped BEFORE matching, both whole-line and trailing ("tcp dport
    # 22 accept # ip note" must not evade on the strength of its own
    # comment), and a rule already constrained by "meta nfproto", "ip", or
    # "ip6" is accepted.
    # Only the image-time placeholder may survive this recipe. The forward
    # chain must not carry an unconditional accept: a bare "accept" there
    # makes the drop policy dead and turns the device into an open router.
    if sed -E 's/#.*$//' ${D}${datadir}/iotgw-firewall/nftables.conf \
        | sed -n '/chain forward/,/^  }/p' | grep -qE '^[[:space:]]*accept[[:space:]]*$'; then
        bbfatal "iotgw-firewall: unconditional accept in the forward chain of nftables.conf"
    fi
    if grep -v '@OTBR_WEBUI_RULES@' ${D}${datadir}/iotgw-firewall/nftables.conf | grep -q '@[A-Z_]*@'; then
        bbfatal "iotgw-firewall: unexpanded placeholder in nftables.conf: $(grep -v '@OTBR_WEBUI_RULES@' ${D}${datadir}/iotgw-firewall/nftables.conf | grep -o '@[A-Z_]*@' | sort -u | tr '\n' ' ')"
    fi
    _nft_file="${D}${datadir}/iotgw-firewall/nftables.conf"
    _nft_bad=$(sed -E 's/#.*$//' "${_nft_file}" \
        | grep -nE '\b(tcp|udp)[[:space:]]+dport\b' \
        | grep -vE '\bmeta[[:space:]]+nfproto\b|\bip6?\b') || true
    if [ -n "${_nft_bad}" ]; then
        bbfatal "iotgw-firewall: the lines below name a port with no address family.
${_nft_bad}
In a 'table inet' they admit the port on IPv4 AND IPv6. Add an explicit \
'meta nfproto ipv4' / 'meta nfproto ipv6' match. See the header comment in \
recipes-security/iotgw-firewall/files/nftables.conf."
    fi
}

FILES:${PN} = "${datadir}/iotgw-firewall/nftables.conf ${datadir}/iotgw-firewall/nftables-otbr-webui.conf"

# Infrastructure (backbone) interface OTBR is attached to (otbr-agent -B); the
# mDNS admit rules are scoped to it. Keep in step with otbr-agent.default.
IOTGW_OTBR_INFRA_IFACE ?= "wlan0"

RDEPENDS:${PN} += "nftables"
