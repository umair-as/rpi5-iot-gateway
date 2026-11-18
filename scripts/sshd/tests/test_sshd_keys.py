"""Tests for iotgw-sshd-keys (sshd host keys in /run, persisted on /data).

The shipped script runs under the POSIX shells available on the host
(busybox ash, dash) with its /run and /data paths rebased onto a temporary
directory, `mountpoint` mocked, and the real ssh-keygen.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "meta-iot-gateway/recipes-connectivity/openssh/files/iotgw-sshd-keys.sh"
SHELLS = [s for s in (["busybox", "ash"], ["dash"]) if shutil.which(s[0])]
TYPES = ("rsa", "ecdsa", "ed25519")

pytestmark = pytest.mark.skipif(not shutil.which("ssh-keygen"), reason="needs ssh-keygen")


def run(tmp_path: Path, shell, mounted=True):
    text = SCRIPT.read_text()
    text = text.replace("/run/sshd-keys", str(tmp_path / "run/sshd-keys"))
    text = text.replace("/data/ssh", str(tmp_path / "data/ssh"))
    rc = 0 if mounted else 1
    script = "\n".join([
        f"mountpoint() {{ return {rc}; }}",
        "restorecon() { :; }",
        text,
    ])
    (tmp_path / "run").mkdir(exist_ok=True)
    (tmp_path / "data").mkdir(exist_ok=True)
    return subprocess.run([*shell, "-c", script], capture_output=True, text=True)


def fp(key: Path):
    out = subprocess.run(["ssh-keygen", "-l", "-f", f"{key}.pub"],
                         capture_output=True, text=True, check=True).stdout.split()
    return int(out[0]), out[1]


def keygen(path: Path, t: str, bits=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ssh-keygen", "-q", "-t", t, "-N", "", "-C", "", "-f", str(path)]
    if bits:
        cmd[4:4] = ["-b", str(bits)]
    subprocess.run(cmd, check=True)


@pytest.fixture(params=SHELLS, ids=[s[0] for s in SHELLS])
def shell(request):
    return request.param


def run_keys(tmp_path):
    return {t: tmp_path / f"run/sshd-keys/ssh_host_{t}_key" for t in TYPES}


def data_keys(tmp_path):
    return {t: tmp_path / f"data/ssh/ssh_host_{t}_key" for t in TYPES}


def test_first_boot_generates_and_persists(tmp_path, shell):
    r = run(tmp_path, shell)
    assert r.returncode == 0, r
    for t in TYPES:
        assert fp(data_keys(tmp_path)[t]) == fp(run_keys(tmp_path)[t])
        assert run_keys(tmp_path)[t].stat().st_mode & 0o777 == 0o600
    assert fp(run_keys(tmp_path)["rsa"])[0] == 4096


def test_existing_keys_keep_their_fingerprints(tmp_path, shell):
    for t in TYPES:
        keygen(data_keys(tmp_path)[t], t, 4096 if t == "rsa" else None)
    before = {t: fp(data_keys(tmp_path)[t]) for t in TYPES}
    r = run(tmp_path, shell)
    assert r.returncode == 0, r
    assert "generating" not in r.stdout
    for t in TYPES:
        assert fp(run_keys(tmp_path)[t]) == before[t]


def test_short_rsa_key_is_replaced_once(tmp_path, shell):
    for t in TYPES:
        keygen(data_keys(tmp_path)[t], t, 3072 if t == "rsa" else None)
    before = {t: fp(data_keys(tmp_path)[t]) for t in TYPES}
    run(tmp_path, shell)
    after = {t: fp(run_keys(tmp_path)[t]) for t in TYPES}
    assert after["rsa"][0] == 4096 and after["rsa"] != before["rsa"]
    assert after["ecdsa"] == before["ecdsa"] and after["ed25519"] == before["ed25519"]
    second = run(tmp_path, shell)
    assert "generating" not in second.stdout
    assert fp(run_keys(tmp_path)["rsa"]) == after["rsa"]


def test_symlinked_key_on_data_is_not_followed(tmp_path, shell):
    elsewhere = tmp_path / "elsewhere/key"
    keygen(elsewhere, "ed25519")
    target = data_keys(tmp_path)["ed25519"]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(elsewhere)
    Path(f"{target}.pub").symlink_to(f"{elsewhere}.pub")
    old = fp(elsewhere)
    run(tmp_path, shell)
    assert not target.is_symlink()
    assert fp(run_keys(tmp_path)["ed25519"]) != old
    assert fp(elsewhere) == old


def test_corrupt_key_is_regenerated(tmp_path, shell):
    k = data_keys(tmp_path)["ecdsa"]
    k.parent.mkdir(parents=True, exist_ok=True)
    k.write_text("garbage\n")
    Path(f"{k}.pub").write_text("garbage\n")
    r = run(tmp_path, shell)
    assert r.returncode == 0, r
    assert fp(run_keys(tmp_path)["ecdsa"])[0] == 256


def test_symlinked_persist_dir_means_this_boot_only(tmp_path, shell):
    (tmp_path / "data").mkdir()
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "data/ssh").symlink_to(tmp_path / "elsewhere")
    r = run(tmp_path, shell)
    assert r.returncode == 0, r
    assert "this boot only" in r.stdout
    assert list((tmp_path / "elsewhere").iterdir()) == []
    for t in TYPES:
        assert run_keys(tmp_path)[t].exists()


def test_no_data_generates_keys_for_this_boot(tmp_path, shell):
    r = run(tmp_path, shell, mounted=False)
    assert r.returncode == 0, r
    assert "this boot only" in r.stdout
    assert not (tmp_path / "data/ssh").exists()
    for t in TYPES:
        assert run_keys(tmp_path)[t].exists()
    assert fp(run_keys(tmp_path)["rsa"])[0] == 4096
