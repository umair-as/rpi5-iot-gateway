"""`make shell` and `make stack` pass no command text through make, and the
preflight bitbake tier builds its kas commands from fixed text only.

kas is replaced by a stub that records its argv, so nothing real runs.
"""

import importlib.util
import os
import pathlib
import shutil
import stat
import subprocess

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "preflight", REPO / "scripts" / "preflight" / "preflight.py"
)
assert _spec and _spec.loader
preflight = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(preflight)

pytestmark = pytest.mark.skipif(
    shutil.which("make") is None, reason="make not installed"
)


def make(*args, env=None):
    return subprocess.run(
        ["make", "-s", "--no-print-directory", *args],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_no_free_text_bitbake_target():
    r = make("-n", "bitbake-task")
    assert r.returncode != 0
    assert "No rule to make target" in r.stderr


@pytest.mark.parametrize(
    "image, last", [("dev", "kas/deepx.yml"), ("prod", "kas/fit-release-trust.yml")]
)
def test_stack_prints_the_composition(image, last):
    r = make("stack", f"IMAGE={image}")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip().endswith(last)
    assert "\n" not in r.stdout.strip()


def test_shell_runs_kas_shell_with_the_stack_only(tmp_path):
    log = tmp_path / "kas.log"
    kas = tmp_path / "kas"
    kas.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{log}"\n')
    kas.chmod(kas.stat().st_mode | stat.S_IXUSR)
    env = dict(
        os.environ, KAS_WORK_DIR=str(tmp_path / "w"), KAS_BUILD_DIR=str(tmp_path / "b")
    )
    stack = make("stack", "IMAGE=desktop").stdout.strip()
    r = make("shell", "IMAGE=desktop", f"KAS={kas}", env=env)
    assert r.returncode == 0, r.stderr
    assert log.read_text().splitlines() == ["shell", stack]


@pytest.mark.parametrize(
    "pn", ["curl", "python3", "linux-iotgw-mainline", "glib-2.0", "gtk+3"]
)
def test_recipe_names_accepted(pn):
    assert preflight.PN_RE.match(pn)


@pytest.mark.parametrize("pn", ["curl;id", "a b", "$(id)", "x`id`", "x'y", "", "-c"])
def test_recipe_names_refused(pn):
    assert not preflight.PN_RE.match(pn)


def test_kas_task_is_fixed_text():
    assert preflight.kas_task("bitbake curl -c patch") == (
        preflight.KAS_SHELL,
        "bitbake curl -c patch",
    )
