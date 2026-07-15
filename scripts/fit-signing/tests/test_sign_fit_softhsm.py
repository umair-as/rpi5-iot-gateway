"""SoftHSM-gated integration tests for sign_fit.py.

Skipped unless SoftHSM/engine_pkcs11 are usable on the host. Exercises
the full sign + verify flow without requiring any YubiKey hardware.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest

from conftest import run_sign_fit


def test_sign_fit_against_softhsm(fixture_fit, softhsm_dev_key):
    """sign-fit subcommand signs a fixture FIT via the SoftHSM token."""
    r = run_sign_fit(
        "sign-fit",
        "--profile", "softhsm-test",
        "--profile-config", str(softhsm_dev_key["profile_config"]),
        "--fit", str(fixture_fit),
        "--verify",
        env=softhsm_dev_key["env"],
    )
    assert r.returncode == 0, f"stdout: {r.stdout}\nstderr: {r.stderr}"
    combined = r.stdout + r.stderr
    assert "mkimage signed" in combined or "Signature written" in combined
    assert "PASS" in combined

    # The structural verify already asserted the expected algo string;
    # cross-check via dumpimage that the FIT carries a Sign value.
    out = subprocess.run(
        ["dumpimage", "-l", str(fixture_fit)],
        capture_output=True, text=True, check=True,
    )
    assert "sha256,rsa2048:iotgw-fit-softhsm-dev" in out.stdout
    assert "Sign value:" in out.stdout


def test_verify_fit_against_dtb(
    fixture_fit, softhsm_dev_key, fixture_dtb_with_pubkey, fit_check_sign_tool,
):
    """verify subcommand runs fit_check_sign and accepts a properly signed FIT."""
    # First sign the FIT with the SoftHSM key.
    sign_result = run_sign_fit(
        "sign-fit",
        "--profile", "softhsm-test",
        "--profile-config", str(softhsm_dev_key["profile_config"]),
        "--fit", str(fixture_fit),
        env=softhsm_dev_key["env"],
    )
    assert sign_result.returncode == 0, sign_result.stderr

    # Then verify it against the DTB carrying the matching pubkey.
    verify_result = run_sign_fit(
        "verify",
        "--fit", str(fixture_fit),
        "--dtb", str(fixture_dtb_with_pubkey),
        "--fit-check-sign-path", fit_check_sign_tool,
    )
    assert verify_result.returncode == 0, (
        f"stdout: {verify_result.stdout}\nstderr: {verify_result.stderr}"
    )
    assert "PASS" in verify_result.stdout


def test_verify_fails_on_unsigned_fit(
    fixture_fit, fixture_dtb_with_pubkey, fit_check_sign_tool, softhsm_dev_key,
):
    """fit_check_sign must reject a FIT that was never signed against this key."""
    # Don't sign — leave fixture_fit with its placeholder hint and no
    # signature value. fit_check_sign should fail.
    r = run_sign_fit(
        "verify",
        "--fit", str(fixture_fit),
        "--dtb", str(fixture_dtb_with_pubkey),
        "--fit-check-sign-path", fit_check_sign_tool,
        check=False,
    )
    assert r.returncode != 0


def test_sign_fit_verbose_preserves_no_op_guard(fixture_fit, softhsm_dev_key, tmp_path):
    """--verbose must still enforce the Signature-written guard.

    Re-runs the silent-no-op scenario with --verbose to confirm the
    capture-then-tee logic does not skip the success-line check.
    """
    bad_cfg = tmp_path / "bad-verbose.yml"
    bad_cfg.write_text(
        f'''
fit_signing_profiles:
  bad:
    key_name_hint: "iotgw-fit-softhsm-dev"
    uri: "pkcs11:token=iotgw-fit-test;object=does-not-exist-verbose;pin-value=1234"
    engine_conf: "{softhsm_dev_key['engine_conf']}"
'''
    )
    r = run_sign_fit(
        "sign-fit",
        "--profile", "bad",
        "--profile-config", str(bad_cfg),
        "--fit", str(fixture_fit),
        "--verbose",
        env=softhsm_dev_key["env"],
        check=False,
    )
    assert r.returncode == 1
    # Verbose mode tees mkimage output, so we should see mkimage's own
    # error trail in stderr (proves the verbose path executed).
    assert (
        "PKCS11" in r.stderr or "Failure" in r.stderr
        or "Bad parameters" in r.stderr or "object not found" in r.stderr
    ), f"verbose mode should expose mkimage output; got stderr: {r.stderr!r}"


def test_sign_fit_silent_no_op_guard(fixture_fit, softhsm_dev_key, tmp_path):
    """A URI that mkimage can't resolve should be detected via the
    `Signature written` log line check, not silently succeed."""
    # Build a profile config that points at a non-existent SoftHSM object
    # but still passes our object= validation. mkimage will fail to find
    # the key.
    bad_cfg = tmp_path / "bad.yml"
    bad_cfg.write_text(
        f'''
fit_signing_profiles:
  bad:
    key_name_hint: "iotgw-fit-softhsm-dev"
    uri: "pkcs11:token={softhsm_dev_key['env'].get('SOFTHSM2_CONF', 'unknown')};object=does-not-exist;pin-value=1234"
    engine_conf: "{softhsm_dev_key['engine_conf']}"
'''
    )
    r = run_sign_fit(
        "sign-fit",
        "--profile", "bad",
        "--profile-config", str(bad_cfg),
        "--fit", str(fixture_fit),
        env=softhsm_dev_key["env"],
        check=False,
    )
    assert r.returncode == 1
