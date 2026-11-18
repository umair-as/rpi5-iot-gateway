"""The firewall ruleset replaces its table in one nft transaction.

/etc/nftables.conf (iotgw-firewall) declares, deletes and redefines
`table inet filter` in one file, and iotgw-nftables.service loads it with a
single `nft -f` on start and reload. A ruleset that fails to load must leave
the previous table in force: no window without filtering, no table removed by
a failed reload. Runs nft in a private user and network namespace.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
CONF = REPO / "meta-iot-gateway/recipes-security/iotgw-firewall/files/nftables.conf"
UNIT = REPO / "meta-iot-gateway/recipes-security/iotgw-nftables/files/iotgw-nftables.service"
FALLBACK = REPO / "meta-iot-gateway/recipes-security/iotgw-nftables/files/iotgw-nftables-fallback.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("nft") is None
    or subprocess.run(["unshare", "-rn", "nft", "list", "ruleset"], capture_output=True).returncode != 0,
    reason="needs nft and unprivileged user+network namespaces")


def rendered():
    """The ruleset as iotgw-firewall's do_install leaves it (placeholders filled)."""
    text = CONF.read_text()
    text = text.replace("@IOTGW_CTR_UID@", "968").replace("@IOTGW_CTR_SUBID_RANGE@", "200000-265535")
    # Without OTBR the recipe deletes the lines holding these markers.
    text = "\n".join(l for l in text.splitlines()
                     if not re.search(r"@(OTBR_RULES|OTBR_FORWARD_RULES|OTBR_WEBUI_RULES)@", l))
    assert not re.search(r"@[A-Z_]+@", text), "unrendered placeholder"
    return text + "\n"


def test_ruleset_is_self_replacing():
    text = rendered()
    head = text.split("table inet filter {", 1)[0]
    assert "\ntable inet filter\n" in head and "\ndelete table inet filter\n" in head


def test_unit_has_no_separate_delete():
    unit = UNIT.read_text()
    assert "delete table" not in unit
    loads = [l for l in unit.splitlines() if l.startswith(("ExecStart=", "ExecReload=")) and " -c " not in l]
    assert loads == ["ExecStart=/usr/sbin/nft -f /etc/nftables.conf",
                     "ExecReload=/usr/sbin/nft -f /etc/nftables.conf"]


def test_fallback_is_self_replacing():
    text = FALLBACK.read_text()
    assert "nft delete table" not in text
    assert "table inet filter\ndelete table inet filter\ntable inet filter {" in text


def test_load_twice_and_failed_reload_keeps_table(tmp_path):
    good = tmp_path / "good.nft"
    good.write_text(rendered())
    broken = tmp_path / "broken.nft"
    broken.write_text(rendered().replace("  chain input {", "  chain input {\n    meta nosuchkey 1 accept", 1))
    script = f"""
set -e
nft -f {good}                       # first load: table absent, created
nft -f {good}                       # reload: replaced in place
before=$(nft list table inet filter)
if nft -f {broken} 2>/dev/null; then echo BROKEN-LOADED; exit 1; fi
after=$(nft list table inet filter)
[ "$before" = "$after" ] && echo UNCHANGED
"""
    r = subprocess.run(["unshare", "-rn", "sh", "-c", script], capture_output=True, text=True)
    assert r.returncode == 0 and "UNCHANGED" in r.stdout, r.stdout + r.stderr
