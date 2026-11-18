"""Tests for record_trial_slot in the RAUC post-install hook
(meta-iot-gateway/recipes-ota/rauc/files/bundle-hooks-fit.sh).

The function is extracted from the shipped hook by name and run under bash
with mountpoint() and the log helpers stubbed, so no device is touched.
"""
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HOOK = REPO / "meta-iot-gateway/recipes-ota/rauc/files/bundle-hooks-fit.sh"


def record_fn() -> str:
    m = re.search(r"^record_trial_slot\(\) \{\n.*?^\}\n", HOOK.read_text(), re.S | re.M)
    assert m, "record_trial_slot() not found in the hook"
    return m.group(0)


def run(tmp_path, *, mounted=True, bootname="B", slot_name="", record_dir=None):
    record_dir = record_dir or tmp_path
    script = "\n".join([
        "set -euo pipefail",
        'log_error() { echo "ERROR: $*"; }',
        'log_info() { echo "INFO: $*"; }',
        f"mountpoint() {{ return {0 if mounted else 1}; }}",
        f'TRIAL_RECORD="{record_dir}/iotgw-trial-slot"',
        record_fn(),
        "record_trial_slot",
    ])
    env = {"PATH": "/usr/bin:/bin", "RAUC_SLOT_BOOTNAME": bootname, "RAUC_SLOT_NAME": slot_name}
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)


def test_happy_path_writes_the_bootname(tmp_path):
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert (tmp_path / "iotgw-trial-slot").read_text() == "B\n"
    assert not (tmp_path / "iotgw-trial-slot.new").exists()


def test_bootname_falls_back_to_slot_name(tmp_path):
    r = run(tmp_path, bootname="", slot_name="rootfs.0")
    assert r.returncode == 0, r.stdout
    assert (tmp_path / "iotgw-trial-slot").read_text() == "A\n"


def test_unmounted_uboot_env_fails(tmp_path):
    r = run(tmp_path, mounted=False)
    assert r.returncode != 0
    assert "/uboot-env is not mounted" in r.stdout
    assert not (tmp_path / "iotgw-trial-slot").exists()


def test_unknown_bootname_fails(tmp_path):
    r = run(tmp_path, bootname="C")
    assert r.returncode != 0
    assert "Unknown bootname" in r.stdout


def test_write_failure_fails_and_leaves_no_temp_file(tmp_path):
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o555)
    try:
        r = run(tmp_path, record_dir=ro)
    finally:
        ro.chmod(0o755)
    assert r.returncode != 0
    assert "Could not write" in r.stdout
    assert list(ro.iterdir()) == []


def test_call_site_refuses_the_install():
    assert re.search(r'^record_trial_slot \|\| die ', HOOK.read_text(), re.M), \
        "the hook must abort when the trial record is not written"
