"""Tests for the retired-overlay cleanup in iotgw-preinit (section 4).

The section is extracted from the shipped script, /data is rebased onto a
temporary directory, and the result runs under the POSIX shells available on
the host (busybox ash, dash). Nothing outside the temporary directory is
touched by a correct implementation; the tests check exactly that.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
PREINIT = REPO / "meta-iot-gateway/recipes-support/iotgw-preinit/files/iotgw-preinit.sh"

SHELLS = [s for s in (["busybox", "ash"], ["dash"]) if shutil.which(s[0])]


def section(data: Path) -> str:
    text = PREINIT.read_text()
    m = re.search(r"^# 4\. Leftover persistent overlays.*?(?=^# 5\. )", text, re.S | re.M)
    assert m, "section 4 not found in iotgw-preinit.sh"
    return m.group(0).replace("/data", str(data))


def run(tmp_path: Path, shell):
    data = tmp_path / "data"
    script = "\n".join([
        f'LOG="{tmp_path}/preinit.log"',
        f'log() {{ echo "$*" >> "{tmp_path}/preinit.log"; }}',
        f'degraded() {{ echo "$1" > "{tmp_path}/degraded"; }}',
        "mountpoint() { return 0; }",
        section(data),
    ])
    return subprocess.run([*shell, "-c", script], capture_output=True, text=True)


@pytest.fixture(params=SHELLS, ids=[s[0] for s in SHELLS])
def shell(request):
    return request.param


def test_symlinked_ancestor_is_not_followed(tmp_path, shell):
    data = tmp_path / "data"
    data.mkdir()
    victim = tmp_path / "elsewhere" / "overlay-reconcile"
    victim.mkdir(parents=True)
    (victim / "keep").write_text("x")
    (data / "iotgw").symlink_to(tmp_path / "elsewhere")
    run(tmp_path, shell)
    assert (victim / "keep").exists(), "cleanup followed a symlinked ancestor"
    assert (tmp_path / "degraded").read_text().startswith("retired-path-ancestor-not-a-directory:")


def test_file_ancestor_is_rejected(tmp_path, shell):
    data = tmp_path / "data"
    data.mkdir()
    (data / "iotgw").write_text("not a dir")
    run(tmp_path, shell)
    assert (data / "iotgw").read_text() == "not a dir"
    assert (tmp_path / "degraded").exists()


def test_real_retired_trees_are_removed(tmp_path, shell):
    data = tmp_path / "data"
    (data / "overlays" / "etc").mkdir(parents=True)
    (data / "iotgw" / "overlay-reconcile" / "state").mkdir(parents=True)
    (data / "iotgw" / "other").write_text("stays")
    run(tmp_path, shell)
    assert not (data / "overlays").exists()
    assert not (data / "iotgw" / "overlay-reconcile").exists()
    assert (data / "iotgw" / "other").read_text() == "stays"
    assert not (tmp_path / "degraded").exists()


def test_leaf_symlink_removes_only_the_link(tmp_path, shell):
    data = tmp_path / "data"
    (data / "iotgw").mkdir(parents=True)
    target = tmp_path / "target"
    target.mkdir()
    (target / "keep").write_text("x")
    (data / "iotgw" / "overlay-reconcile").symlink_to(target)
    run(tmp_path, shell)
    assert not (data / "iotgw" / "overlay-reconcile").is_symlink()
    assert (target / "keep").exists()


def test_missing_ancestor_is_not_degraded(tmp_path, shell):
    (tmp_path / "data").mkdir()
    run(tmp_path, shell)
    assert not (tmp_path / "degraded").exists()


def test_shells_available():
    assert SHELLS, "need busybox or dash on the host to exercise the pre-init shell"
