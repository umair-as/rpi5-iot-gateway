"""Tests for preflight.py path mapping and build-directory guard. No BitBake."""

import fcntl
import importlib.util
import os
import pathlib
import subprocess

import pytest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("preflight", HERE.parent / "preflight.py")
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)

L = "meta-iot-gateway/"


@pytest.mark.parametrize("path, expected", [
    (L + "recipes-security/refpolicy/files/policy/iotgw.te", {"selinux-policy", "refpolicy-compile"}),
    ("scripts/selinux/policy-raw-type-check.py", {"selinux-policy"}),
    (L + "recipes-kernel/linux/files/fragments/desktop.cfg", {"kernel-fragment-gate", "kernel-configure"}),
    (L + "classes/iotgw-kernel-fragments.bbclass", {"kernel-fragment-gate", "kernel-configure", "parse"}),
    (L + "recipes-ota/rauc/files/bundle-hooks-fit.sh", {"boot-scripts", "recipe-patch"}),
    ("scripts/sbom-cve/cve-report.py", {"sbom-cve"}),
    ("scripts/fit-signing/sign_fit.py", {"sign-fit"}),
    ("scripts/agent-build/agent-build.py", {"agent-build"}),
    ("scripts/preflight/preflight.py", {"preflight"}),
    ("scripts/tpm/tpm-encrypted-store-dev.sh", {"host-tools"}),
    ("scripts/lib/host-ssh.sh", {"host-tools"}),
    ("scripts/run-target-checks.sh", {"host-tools"}),
    ("scripts/deepx/dxm1-push-model.sh", {"host-tools"}),
    ("scripts/selinux/policy-trial.sh", {"selinux-policy", "host-tools"}),
    ("scripts/hooks/commit-msg", {"tooling"}),
    ("scripts/tests/test_makefile.py", {"tooling"}),
    ("Makefile", {"tooling"}),
    (L + "conf/distro/iotgw.conf", {"parse"}),
    ("kas/desktop.yml", {"parse"}),
    ("rpi5.yml", {"parse"}),
    (L + "recipes-core/images/iot-gw-image-dev.bb", {"parse"}),
    ("docs/SELINUX.md", set()),
])
def test_classify(path, expected):
    assert pf.classify(path) == expected


def test_recipe_names_from_bbappend_and_packagegroups_skipped():
    assert "rauc" in pf.recipe_names(L + "recipes-ota/rauc/files/x")
    assert pf.recipe_names(L + "recipes-core/packagegroups/packagegroup-iot-gw-base.bb") == set()
    assert pf.recipe_names(L + "recipes-kernel/linux/files/0001.patch") == set()


def test_targeted_task_drops_parse(capsys):
    pf.main(["--plan", "--paths", L + "conf/distro/iotgw.conf",
             L + "recipes-security/refpolicy/files/policy/iotgw.te"])
    out = capsys.readouterr().out
    assert "refpolicy-compile" in out and "] parse " not in out


def test_build_dir_busy(tmp_path, monkeypatch):
    monkeypatch.setenv("KAS_BUILD_DIR", str(tmp_path))
    assert pf.build_dir_busy() is None
    # A lock file left behind by a finished build does not count as busy.
    for name in (".agent-build.lock", "bitbake.lock"):
        (tmp_path / name).touch()
    assert pf.build_dir_busy() is None
    for name, word in ((".agent-build.lock", "agent-build"), ("bitbake.lock", "BitBake")):
        with (tmp_path / name).open("a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            # flock is per open file description: a second open() conflicts.
            assert word in pf.build_dir_busy()
        assert pf.build_dir_busy() is None


def test_bitbake_tier_refused_when_busy(tmp_path, monkeypatch):
    monkeypatch.setenv("KAS_BUILD_DIR", str(tmp_path))
    ran = []
    monkeypatch.setattr(pf, "run", lambda argv: ran.append(argv) or 0)
    with (tmp_path / "bitbake.lock").open("a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        rc = pf.main(["--bitbake", "--paths", L + "conf/distro/iotgw.conf"])
    assert rc == 3
    assert not any("parse" in a for argv in ran for a in argv)


def test_changed_paths_default_base_is_the_merge_base(tmp_path, monkeypatch):
    """A branch whose work is committed still has changed paths."""
    env = dict(
        os.environ,
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="t",
        GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t",
        GIT_COMMITTER_EMAIL="t@example.invalid",
    )

    def git(*args):
        subprocess.run(
            ["git", "-C", str(tmp_path), *args],
            env=env,
            check=True,
            capture_output=True,
        )

    git("init", "-q", "-b", "main")
    (tmp_path / "a").write_text("a")
    git("add", "a")
    git("commit", "-q", "-m", "base")
    git("checkout", "-q", "-b", "topic")
    (tmp_path / "committed").write_text("c")
    git("add", "committed")
    git("commit", "-q", "-m", "topic")
    (tmp_path / "a").write_text("modified")
    (tmp_path / "untracked").write_text("u")
    for k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"):
        monkeypatch.setenv(k, env[k])
    monkeypatch.setattr(pf, "REPO", tmp_path)
    assert pf.changed_paths(None) == ["a", "committed", "untracked"]


def test_no_changed_paths_warns(monkeypatch, capsys):
    monkeypatch.setattr(pf, "changed_paths", lambda base: [])
    assert pf.main(["--plan"]) == 0
    assert "WARNING: no changed paths" in capsys.readouterr().out
