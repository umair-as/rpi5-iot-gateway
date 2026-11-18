"""iotgw_rootfs_selinux_permissive_gate (meta-iot-gateway/classes/iotgw-rootfs.bbclass).

The function is extracted from the class and run under bash against a fake
policy store, with bbfatal/bbwarn stubbed; BitBake ${VAR} references resolve
as shell variables.
"""
import bz2
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
CLASS = REPO / "meta-iot-gateway/classes/iotgw-rootfs.bbclass"


def gate_fn():
    m = re.search(r"^iotgw_rootfs_selinux_permissive_gate\(\) \{\n.*?^\}\n", CLASS.read_text(), re.S | re.M)
    assert m, "gate not found"
    return m.group(0)


def run(tmp_path, *, permissive=(), expected="", prod=False):
    store = tmp_path / "rootfs/var/lib/selinux/mcs/active/modules/400/iotgw"
    store.mkdir(parents=True)
    cil = "".join(f"(typepermissive {d})\n" for d in permissive) + "(type iotgw_x_t)\n"
    (store / "cil").write_bytes(bz2.compress(cil.encode()))
    script = "\n".join([
        'bbfatal() { echo "FATAL: $*"; exit 1; }',
        'bbwarn() { echo "WARN: $*"; }',
        f'IMAGE_ROOTFS="{tmp_path}/rootfs"', 'localstatedir=/var',
        f'IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED="{expected}"',
        f'IOTGW_PROD_HYGIENE_GATE="{1 if prod else 0}"',
        gate_fn(), "iotgw_rootfs_selinux_permissive_gate", "echo DONE",
    ])
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return r.returncode, r.stdout


@pytest.mark.parametrize("kw,ok,msg", [
    ({}, True, ""),
    ({"prod": True}, True, ""),
    ({"permissive": ["iotgw_new_t"]}, False, "not in IOTGW_SELINUX_PERMISSIVE_DOMAINS_EXPECTED"),
    ({"permissive": ["iotgw_new_t"], "expected": "iotgw_new_t"}, True, "WARN"),
    # Prod: the staging allowlist does not apply.
    ({"permissive": ["iotgw_new_t"], "expected": "iotgw_new_t", "prod": True}, False, "not empty in a prod image"),
    ({"expected": "iotgw_new_t", "prod": True}, False, "not empty in a prod image"),
    ({"permissive": ["iotgw_new_t"], "prod": True}, False, "prod image may not ship"),
])
def test_gate(tmp_path, kw, ok, msg):
    rc, out = run(tmp_path, **kw)
    assert (rc == 0 and "DONE" in out) == ok, out
    assert msg in out, out
