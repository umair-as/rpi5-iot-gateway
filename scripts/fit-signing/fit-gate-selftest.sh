#!/usr/bin/env bash
#
# Negative self-test for meta-iot-gateway/scripts/iotgw-fit-gate.py. Builds
# throwaway keys, anchors and FITs in a temp dir and checks the gate accepts
# the good pairs and rejects every bad one: optional key, no anchor, wrong
# algo, a skipped trust root, an unexpected extra key, two keys without
# required-mode, and unsigned, foreign-signed, under-covered and tampered FITs.
#
#   scripts/fit-signing/fit-gate-selftest.sh [--checker <fit_check_sign>]
#
# The checker defaults to the build's native fit_check_sign.
# Needs openssl, mkimage, dtc, fdtput, fdtget. Exit 0 when every case matches.

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GATE="$ROOT/meta-iot-gateway/scripts/iotgw-fit-gate.py"
CHECKER=""
[ "${1:-}" = "--checker" ] && CHECKER=$2
if [ -z "$CHECKER" ]; then
    CHECKER=$(ls "$ROOT"/build/tmp/sysroots-components/x86_64/u-boot-tools-native/usr/bin/fit_check_sign 2>/dev/null | head -1)
fi
[ -x "$CHECKER" ] || { echo "no fit_check_sign (build u-boot-tools-native or pass --checker)" >&2; exit 2; }
for t in openssl mkimage dtc fdtput fdtget; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W" || exit 2
mkdir keys
for k in good other; do
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/$k.key 2>/dev/null
    openssl req -batch -new -x509 -key keys/$k.key -out keys/$k.crt -subj "/CN=$k" 2>/dev/null
done
head -c 4096 /dev/urandom > kernel.bin
echo '/dts-v1/; / { model = "selftest"; };' | dtc -q -O dtb -o board.dtb -
echo '/dts-v1/; / { };' | dtc -q -O dtb -o empty.dtb -

its() { # key name, sign-images list
    cat <<EOF
/dts-v1/;
/ { description = "fit-gate selftest"; #address-cells = <1>;
  images {
    kernel-1 { data = /incbin/("kernel.bin"); type = "kernel"; arch = "arm64"; os = "linux"; compression = "none"; load = <0x0>; entry = <0x0>; hash-1 { algo = "sha256"; }; };
    fdt-1 { data = /incbin/("board.dtb"); type = "flat_dt"; arch = "arm64"; compression = "none"; hash-1 { algo = "sha256"; }; };
  };
  configurations { default = "conf-A";
    conf-A { description = "selftest"; kernel = "kernel-1"; fdt = "fdt-1";
      signature-1 { algo = "sha256,rsa2048"; key-name-hint = "$1"; sign-images = $2; }; };
  };
};
EOF
}
its good '"kernel", "fdt"' > good.its
its good '"kernel"'        > uncovered.its
its other '"kernel", "fdt"' > other.its
cp empty.dtb anchor.dtb
mkimage -q -f good.its -k keys -K anchor.dtb -r good.itb >/dev/null || exit 2
mkimage -q -f uncovered.its -k keys uncovered.itb >/dev/null || exit 2
cp empty.dtb other-anchor.dtb
mkimage -q -f other.its -k keys -K other-anchor.dtb -r other.itb >/dev/null || exit 2

cp good.itb unsigned.itb; fdtput -r unsigned.itb /configurations/conf-A/signature-1
cp good.itb tampered.itb
off=$(( $(grep -obUa "$(head -c 8 kernel.bin | od -An -tx1 | tr -d ' \n' | sed 's/../\\x&/g' | xargs -0 printf '%b')" tampered.itb | head -1 | cut -d: -f1) + 64 ))
b=$(od -An -tu1 -j"$off" -N1 tampered.itb | tr -d ' ')
printf "\\$(printf '%03o' $((b ^ 1)))" | dd of=tampered.itb bs=1 seek="$off" conv=notrunc status=none
cp anchor.dtb optional.dtb; fdtput -d optional.dtb /signature/key-good required
cp anchor.dtb two-keys.dtb
mkimage -q -f other.its -k keys -K two-keys.dtb -r other2.itb >/dev/null || exit 2
cp two-keys.dtb two-keys-any.dtb; fdtput -t s two-keys-any.dtb /signature required-mode any

pass=0 fail=0
A=(--algo "sha256,rsa2048" --bits 2048)
expect() { # pass|fail, description, gate args...
    local want=$1 desc=$2; shift 2
    if python3 "$GATE" "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "ok    $desc"
    else fail=$((fail + 1)); echo "WRONG $desc (expected $want, got $got)"; fi
}
expect pass "anchor: required key"                anchor --dtb anchor.dtb --keys good "${A[@]}"
expect fail "anchor: optional key"                anchor --dtb optional.dtb --keys good "${A[@]}"
expect fail "anchor: no /signature"               anchor --dtb empty.dtb --keys good "${A[@]}"
expect fail "anchor: wrong algo"                  anchor --dtb anchor.dtb --keys good --algo sha256,rsa4096 --bits 4096
expect fail "anchor: enabled root absent"         anchor --dtb other-anchor.dtb --keys good "${A[@]}"
expect fail "anchor: enabled root skipped"        anchor --dtb anchor.dtb --keys good other "${A[@]}"
expect fail "anchor: unexpected extra key"        anchor --dtb two-keys-any.dtb --keys good "${A[@]}"
expect fail "anchor: two keys, no required-mode"  anchor --dtb two-keys.dtb --keys good other "${A[@]}"
expect pass "anchor: two keys, required-mode any" anchor --dtb two-keys-any.dtb --keys good other "${A[@]}"
expect pass "fit: signed"                         fit --dtb anchor.dtb --fit good.itb --checker "$CHECKER"
expect pass "fit: signed, two-key anchor"         fit --dtb two-keys-any.dtb --fit good.itb --checker "$CHECKER"
expect fail "fit: unsigned"                       fit --dtb anchor.dtb --fit unsigned.itb --checker "$CHECKER"
expect fail "fit: signed by another key"          fit --dtb anchor.dtb --fit other.itb --checker "$CHECKER"
expect fail "fit: signature omits the DTB"        fit --dtb anchor.dtb --fit uncovered.itb --checker "$CHECKER"
expect fail "fit: kernel byte changed"            fit --dtb anchor.dtb --fit tampered.itb --checker "$CHECKER"
expect fail "fit: missing file"                   fit --dtb anchor.dtb --fit absent.itb --checker "$CHECKER"
echo "TOTAL pass=$pass fail=$fail (checker: $CHECKER)"
[ "$fail" -eq 0 ]
