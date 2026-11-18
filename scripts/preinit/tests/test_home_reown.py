"""Tests for reown_homes in iotgw-preinit (/data/home ownership after a UID change).

The function is extracted from the shipped script, /data and /etc/passwd are
rebased onto a temporary directory, and chown/stat are stubs: the tests run
unprivileged, so the stub records what would be re-owned instead of doing it.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
PREINIT = REPO / "meta-iot-gateway/recipes-support/iotgw-preinit/files/iotgw-preinit.sh"

SHELLS = [s for s in (["busybox", "ash"], ["dash"]) if shutil.which(s[0])]


def function(tmp: Path) -> str:
    text = PREINIT.read_text()
    m = re.search(r"^reown_homes\(\) \{.*?^\}\n", text, re.S | re.M)
    assert m, "reown_homes not found in iotgw-preinit.sh"
    return (m.group(0).replace("/data/home", str(tmp / "data/home"))
            .replace("/etc/passwd", str(tmp / "passwd")))


def run(tmp: Path, shell, owners: dict, passwd: str, chown_rc: int = 0):
    (tmp / "passwd").write_text(passwd)
    own = "\n".join(f'  "{tmp}/data/home/{d}") echo {u} ;;' for d, u in owners.items())
    script = "\n".join([
        f'LOG="{tmp}/preinit.log"',
        f'log() {{ echo "$*" >> "{tmp}/preinit.log"; }}',
        f'stat() {{ case "$3" in\n{own}\n  *) return 1 ;; esac; }}',
        f'chown() {{ echo "$*" >> "{tmp}/chown.calls"; return {chown_rc}; }}',
        function(tmp),
        "reown_homes",
    ])
    r = subprocess.run([*shell, "-c", script], capture_output=True, text=True)
    calls = (tmp / "chown.calls").read_text().splitlines() if (tmp / "chown.calls").exists() else []
    logtxt = (tmp / "preinit.log").read_text() if (tmp / "preinit.log").exists() else ""
    return r, calls, logtxt


PASSWD = ("root:x:0:0:root:/root:/bin/sh\n"
          "weston:x:1000:1000::/home/weston:/bin/sh\n"
          "devel:x:1001:1001::/home/devel:/bin/bash\n"
          "dxdemo:x:990:990::/nonexistent:/sbin/nologin\n")


@pytest.fixture(params=SHELLS, ids=[s[0] for s in SHELLS])
def shell(request):
    return request.param


def homes(tmp: Path, *names):
    for n in names:
        (tmp / "data/home" / n).mkdir(parents=True)


def test_mismatched_home_is_reowned(tmp_path, shell):
    homes(tmp_path, "devel", "weston")
    r, calls, log = run(tmp_path, shell, {"devel": 1000, "weston": 1000}, PASSWD)
    assert r.returncode == 0, r.stderr
    assert calls == [f"-R -h 1001:1001 {tmp_path}/data/home/devel"]
    assert "re-owned" in log and "from uid 1000 to 1001:1001" in log


def test_matching_homes_are_untouched(tmp_path, shell):
    homes(tmp_path, "devel", "weston")
    _, calls, log = run(tmp_path, shell, {"devel": 1001, "weston": 1000}, PASSWD)
    assert calls == [] and log == ""


def test_user_without_home_under_home_is_skipped(tmp_path, shell):
    homes(tmp_path, "dxdemo")
    _, calls, _ = run(tmp_path, shell, {"dxdemo": 0}, PASSWD)
    assert calls == []


def test_dir_without_a_user_is_skipped(tmp_path, shell):
    homes(tmp_path, "olduser")
    _, calls, _ = run(tmp_path, shell, {"olduser": 1000}, PASSWD)
    assert calls == []


def test_symlinked_home_is_not_reowned(tmp_path, shell):
    (tmp_path / "data/home").mkdir(parents=True)
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "data/home/devel").symlink_to(tmp_path / "elsewhere")
    _, calls, _ = run(tmp_path, shell, {"devel": 1000}, PASSWD)
    assert calls == []


def test_unreadable_owner_is_skipped(tmp_path, shell):
    homes(tmp_path, "devel")
    _, calls, _ = run(tmp_path, shell, {}, PASSWD)
    assert calls == []


def test_chown_failure_is_logged_not_fatal(tmp_path, shell):
    homes(tmp_path, "devel")
    r, calls, log = run(tmp_path, shell, {"devel": 1000}, PASSWD, chown_rc=1)
    assert r.returncode == 0
    assert len(calls) == 1 and "WARN: re-owning /data/home/devel failed".replace("/data/home", f"{tmp_path}/data/home") in log
