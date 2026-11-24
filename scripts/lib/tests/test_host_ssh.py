"""SSH helpers verify the gateway's host key unless told otherwise.

ssh and scp are shell-function stubs loaded through BASH_ENV that record
their arguments; no connection is made.
"""

from __future__ import annotations

import os
import pathlib
import subprocess

import pytest

SCRIPTS = pathlib.Path(__file__).resolve().parents[2]
LIB = SCRIPTS / "lib" / "host-ssh.sh"
INSECURE = ("StrictHostKeyChecking=no", "UserKnownHostsFile=/dev/null")

STUBS = r"""
ssh() { printf 'MOCK_SSH %s\n' "$*" >> "$STUB_LOG"; cat >/dev/null; return 0; }
scp() { printf 'MOCK_SCP %s\n' "$*" >> "$STUB_LOG"; return 0; }
"""


def opts(**env):
    r = subprocess.run(
        ["bash", "-c", f'. "{LIB}"; iotgw_ssh_host_key_opts'],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
        check=True,
    )
    return r.stdout, r.stderr


def clean_env(**extra):
    env = {
        k: v
        for k, v in os.environ.items()
        if k
        not in (
            "IOTGW_SSH_OPTS",
            "IOTGW_SSH_INSECURE",
            "IOTGW_KNOWN_HOSTS",
            "IOTGW_REMOTE_ENV",
        )
    }
    env.update(extra)
    return env


def test_default_verifies_host_key():
    out, err = opts(IOTGW_SSH_INSECURE="0")
    assert "StrictHostKeyChecking=accept-new" in out
    assert not any(flag in out for flag in INSECURE)
    assert err == ""


def test_known_hosts_file_is_used():
    out, _ = opts(IOTGW_KNOWN_HOSTS="/tmp/bench_known_hosts")
    assert "UserKnownHostsFile=/tmp/bench_known_hosts" in out
    assert "StrictHostKeyChecking=accept-new" in out


def test_insecure_only_when_selected_and_warns():
    out, err = opts(IOTGW_SSH_INSECURE="1")
    assert all(flag in out for flag in INSECURE)
    assert "NOT verified" in err


@pytest.fixture
def stubs(tmp_path):
    f = tmp_path / "stubs.sh"
    f.write_text(STUBS)
    return f, tmp_path / "calls.log"


@pytest.mark.parametrize("insecure", [False, True])
def test_run_target_checks(stubs, insecure):
    stub, log = stubs
    env = clean_env(BASH_ENV=str(stub), STUB_LOG=str(log), IOTGW_SSH_USER="root")
    if insecure:
        env["IOTGW_SSH_INSECURE"] = "1"
    subprocess.run(
        [
            "bash",
            str(SCRIPTS / "run-target-checks.sh"),
            "audit-fixture.invalid",
            "platform-smoke",
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = log.read_text()
    assert "MOCK_SSH" in calls
    assert all(flag in calls for flag in INSECURE) is insecure
    if not insecure:
        assert not any(flag in calls for flag in INSECURE)
        assert "StrictHostKeyChecking=accept-new" in calls


def test_dxm1_push_model(stubs, tmp_path):
    stub, log = stubs
    model = tmp_path / "model.dxnn"
    model.write_bytes(b"fixture")
    env = clean_env(BASH_ENV=str(stub), STUB_LOG=str(log))
    subprocess.run(
        [
            "bash",
            str(SCRIPTS / "deepx" / "dxm1-push-model.sh"),
            "audit-fixture.invalid",
            str(model),
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = log.read_text()
    assert "MOCK_SCP" in calls and "MOCK_SSH" in calls
    assert not any(flag in calls for flag in INSECURE)
    assert calls.count("StrictHostKeyChecking=accept-new") == calls.count("MOCK_")


def test_no_script_hardcodes_insecure_ssh():
    offenders = []
    for path in SCRIPTS.rglob("*"):
        if not path.is_file() or path == LIB or "tests" in path.parts:
            continue
        if path.suffix not in (".sh", ".py", "") and not path.name.endswith(".bash"):
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        if any(flag in text for flag in INSECURE):
            offenders.append(str(path.relative_to(SCRIPTS)))
    assert offenders == [], f"insecure SSH options outside lib/host-ssh.sh: {offenders}"
