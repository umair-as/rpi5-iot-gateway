"""Tests for preflight.py path mapping and build-directory guard. No BitBake."""

import fcntl
import importlib.util
import pathlib

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
