"""Unit tests for sign_fit.py — exercise argparse, profile loading,
and validation paths without needing SoftHSM or any signing token.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import textwrap

import pytest

from conftest import SIGN_FIT_PY, run_sign_fit


def test_help_prints_subcommands():
    r = run_sign_fit("--help")
    assert "sign-fit" in r.stdout
    assert "sign-bootfiles" in r.stdout
    assert "verify" in r.stdout
    assert "print-profile" in r.stdout


def test_print_profile_yubikey(tmp_path):
    r = run_sign_fit("print-profile", "--profile", "yubikey-9a")
    assert r.returncode == 0
    assert "yubikey-9a" in r.stdout
    assert "iotgw-fit-yk-2026" in r.stdout
    assert "pkcs11:object=Private%20key%20for%20PIV%20Authentication" in r.stdout


def test_print_profile_softhsm(tmp_path):
    r = run_sign_fit("print-profile", "--profile", "softhsm-dev")
    assert r.returncode == 0
    assert "softhsm-dev" in r.stdout
    assert "iotgw-fit-softhsm-dev" in r.stdout
    assert "pkcs11:object=iotgw-fit-softhsm-dev" in r.stdout


def test_print_profile_custom_config(tmp_path):
    cfg = tmp_path / "custom.yml"
    cfg.write_text(
        textwrap.dedent(
            """\
            fit_signing_profiles:
              custom:
                key_name_hint: "custom-hint"
                uri: "pkcs11:object=custom-label"
                engine_conf: "/tmp/does-not-need-to-exist.cnf"
            """
        )
    )
    r = run_sign_fit("print-profile", "--profile", "custom", "--profile-config", str(cfg))
    assert r.returncode == 0
    assert "custom-hint" in r.stdout
    assert "custom-label" in r.stdout


def test_unknown_profile_is_fatal():
    r = run_sign_fit("print-profile", "--profile", "does-not-exist", check=False)
    assert r.returncode == 1
    assert "unknown profile" in r.stderr


def test_explicit_overrides_without_profile(tmp_path):
    """--key-name-hint + --uri + --engine-conf can replace --profile."""
    r = run_sign_fit(
        "print-profile",
        "--key-name-hint", "manual-hint",
        "--uri", "pkcs11:object=manual",
        "--engine-conf", "/tmp/none.cnf",
    )
    assert r.returncode == 0
    assert "manual-hint" in r.stdout
    assert "pkcs11:object=manual" in r.stdout


def test_missing_explicit_overrides_is_fatal():
    """No --profile and incomplete overrides should fail clearly."""
    r = run_sign_fit("print-profile", "--key-name-hint", "x", check=False)
    assert r.returncode == 1
    assert "--profile" in r.stderr or "required" in r.stderr


def test_uri_without_object_rejected(tmp_path, fixture_fit):
    """sign-fit must reject URIs without object= (mkimage URI synthesis trap)."""
    r = run_sign_fit(
        "sign-fit",
        "--fit", str(fixture_fit),
        "--key-name-hint", "test-key",
        "--uri", "pkcs11:id=%01;type=private",  # missing object=
        "--engine-conf", "/tmp/none.cnf",
        check=False,
    )
    assert r.returncode == 1
    assert "object=" in r.stderr


def test_non_pkcs11_uri_rejected(fixture_fit):
    r = run_sign_fit(
        "sign-fit",
        "--fit", str(fixture_fit),
        "--key-name-hint", "test-key",
        "--uri", "file:///some/path?object=x",
        "--engine-conf", "/tmp/none.cnf",
        check=False,
    )
    assert r.returncode == 1
    assert "pkcs11:" in r.stderr


def test_rewrite_only_mutates_fit(fixture_fit, tmp_path):
    """--rewrite-only should change the FIT's key-name-hint but not sign."""
    new_hint = "rewritten-hint"
    # Use rewrite-only so we don't need an engine_conf or token. The
    # validate path requires engine_conf only when signing.
    r = run_sign_fit(
        "sign-fit",
        "--fit", str(fixture_fit),
        "--key-name-hint", new_hint,
        "--uri", "pkcs11:object=anything",
        "--engine-conf", "/tmp/none.cnf",
        "--rewrite-only",
    )
    assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"

    # Confirm the hint was rewritten via fdtget.
    got = subprocess.run(
        ["fdtget", str(fixture_fit), "/configurations/conf-1/signature-1", "key-name-hint"],
        capture_output=True, text=True, check=True,
    )
    assert got.stdout.strip() == new_hint


def test_fit_check_sign_discovery_via_env(tmp_path, monkeypatch):
    """verify subcommand respects IOTGW_FIT_CHECK_SIGN override."""
    # Provide a fake binary that doesn't exist; we just want the error
    # to come from there (proves the env var is consulted).
    monkeypatch.setenv("IOTGW_FIT_CHECK_SIGN", "/nonexistent/fit_check_sign")
    r = run_sign_fit("verify", "--fit", "/tmp/x", "--dtb", "/tmp/y", check=False)
    assert r.returncode == 1
    assert "IOTGW_FIT_CHECK_SIGN" in r.stderr or "not at" in r.stderr


# ---------------------------------------------------------------------------
# Shim default profile injection
# ---------------------------------------------------------------------------


import subprocess as _subprocess
from conftest import SCRIPTS_DIR


def _run_shim(shim: str, *args: str) -> _subprocess.CompletedProcess:
    return _subprocess.run(
        ["bash", str(SCRIPTS_DIR / shim), *args],
        capture_output=True, text=True, check=False,
    )


def test_sign_fit_shim_defaults_to_yubikey_profile(tmp_path):
    """`sign-fit.sh --fit <missing>` must fail on FIT lookup, not on missing profile.

    Reproduces the legacy invocation pattern: a bare shim call with no
    --profile and no signing-identity flags should resolve to the
    YubiKey slot 9a profile by default. Reaching the FIT-lookup stage
    proves the profile loaded; failing earlier (e.g. "either --profile
    or ... required") would mean the default was never injected.
    """
    missing = tmp_path / "nonexistent-fit"
    r = _run_shim("sign-fit.sh", "--fit", str(missing))
    assert r.returncode == 1
    assert "fitImage not found" in r.stderr
    # Negative assertion: the build_profile "required-flags-missing"
    # error must NOT have triggered.
    assert "either --profile" not in r.stderr


def test_sign_bootfiles_shim_defaults_to_yubikey_profile(tmp_path):
    """`sign-bootfiles-fit.sh -- --verify` with no archive must fail on archive lookup."""
    missing_archive = tmp_path / "nonexistent.tar.gz"
    r = _run_shim(
        "sign-bootfiles-fit.sh",
        "--archive", str(missing_archive),
        "--", "--verify",
    )
    assert r.returncode == 1
    assert "archive not found" in r.stderr


def _assert_explicit_profile_not_overridden(stderr: str) -> None:
    """Structural invariants for explicit --profile shim test cases.

    Tests must not assume the host's SoftHSM provisioning state. The
    only things we can portably assert:
      - the failure must not be "either --profile or … required"
        (that would mean the shim stripped --profile and failed to
        inject any default either)
      - the failure must not mention the yubikey-9a engine_conf path
        (that would mean the shim wrongly injected --profile
        yubikey-9a on top of the explicit profile)
      - the failure must be one of the two benign downstream errors:
        missing FIT (engine_conf exists) or missing engine_conf (no
        SoftHSM provisioned). Either proves the profile loaded and
        validation got past the URI/profile stage.
    """
    assert "either --profile" not in stderr, (
        f"explicit --profile was dropped before reaching Python; stderr: {stderr!r}"
    )
    assert "rauc-ca/fit/openssl-engine.cnf" not in stderr, (
        f"yubikey-9a engine_conf path appeared — shim injected the wrong default; "
        f"stderr: {stderr!r}"
    )
    assert "fitImage not found" in stderr or "engine conf not found" in stderr, (
        f"expected benign downstream failure, got: {stderr!r}"
    )


def test_shim_respects_explicit_profile(tmp_path):
    """`--profile softhsm-dev` must reach Python without yubikey-9a injection."""
    missing = tmp_path / "nonexistent-fit"
    r = _run_shim(
        "sign-fit.sh",
        "--profile", "softhsm-dev",
        "--fit", str(missing),
    )
    assert r.returncode == 1
    _assert_explicit_profile_not_overridden(r.stderr)


def test_shim_respects_explicit_profile_eq(tmp_path):
    """Same as above but with the `--profile=NAME` long-option form."""
    missing = tmp_path / "nonexistent-fit"
    r = _run_shim(
        "sign-fit.sh",
        "--profile=softhsm-dev",
        "--fit", str(missing),
    )
    assert r.returncode == 1
    _assert_explicit_profile_not_overridden(r.stderr)


def test_shim_partial_override_engine_conf(tmp_path):
    """`--engine-conf <path>` alone must inherit the yubikey-9a profile's other fields.

    Old bash behavior: a caller could override just engine_conf and
    keep the default key hint + URI. With the shim always injecting
    `--profile yubikey-9a`, Python applies engine_conf as a per-field
    override on top, then proceeds to FIT validation.
    """
    missing = tmp_path / "nonexistent-fit"
    fake_engine = tmp_path / "fake-engine.cnf"
    fake_engine.write_text("# placeholder\n")  # exists so engine_conf validation passes
    r = _run_shim(
        "sign-fit.sh",
        "--engine-conf", str(fake_engine),
        "--fit", str(missing),
    )
    assert r.returncode == 1
    # Must fail on the missing FIT, NOT on "profile required" or
    # "either --profile or ... required".
    assert "fitImage not found" in r.stderr, (
        f"partial --engine-conf override regressed; stderr: {r.stderr!r}"
    )


def test_shim_partial_override_uri(tmp_path):
    """`--uri <pkcs11:object=...>` alone must inherit the yubikey-9a profile's other fields."""
    missing = tmp_path / "nonexistent-fit"
    r = _run_shim(
        "sign-fit.sh",
        "--uri", "pkcs11:object=alternate-label",
        "--fit", str(missing),
    )
    assert r.returncode == 1
    assert "fitImage not found" in r.stderr


def test_shim_partial_override_key_label(tmp_path):
    """`--key-label <NAME>` alone must inherit the yubikey-9a profile's engine_conf.

    The legacy alias derives uri=pkcs11:object=<urlencoded NAME>, but
    engine_conf must come from the yubikey-9a profile default.
    """
    missing = tmp_path / "nonexistent-fit"
    r = _run_shim(
        "sign-fit.sh",
        "--key-label", "custom-label",
        "--fit", str(missing),
    )
    assert r.returncode == 1
    # Either fitImage-not-found (engine_conf exists on operator host) or
    # engine_conf-not-found (yubikey-9a default missing on this host).
    # The deprecation warning must surface either way.
    assert "--key-label is deprecated" in r.stderr
    assert "fitImage not found" in r.stderr or "engine conf not found" in r.stderr


# ---------------------------------------------------------------------------
# Legacy --key-label behavior
# ---------------------------------------------------------------------------


def test_key_label_print_profile_derives_uri(tmp_path):
    """--key-label sets the hint and derives uri=pkcs11:object=<encoded>."""
    r = run_sign_fit(
        "print-profile",
        "--key-label", "Private key for PIV Authentication",
        "--engine-conf", "/tmp/none.cnf",
    )
    assert r.returncode == 0
    assert "key_name_hint  : Private key for PIV Authentication" in r.stdout
    # URL-encoded spaces.
    assert "pkcs11:object=Private%20key%20for%20PIV%20Authentication" in r.stdout
    # Deprecation warning surfaces via the logging stream (stderr).
    assert "--key-label is deprecated" in r.stderr


def test_key_label_conflicts_with_key_name_hint():
    r = run_sign_fit(
        "print-profile",
        "--key-label", "x",
        "--key-name-hint", "y",
        "--engine-conf", "/tmp/none.cnf",
        check=False,
    )
    assert r.returncode == 1
    assert "mutually exclusive" in r.stderr


def test_key_label_uri_override_wins(tmp_path):
    """If --uri is explicitly supplied alongside --key-label, --uri wins."""
    r = run_sign_fit(
        "print-profile",
        "--key-label", "label",
        "--uri", "pkcs11:object=explicit",
        "--engine-conf", "/tmp/none.cnf",
    )
    assert r.returncode == 0
    assert "pkcs11:object=explicit" in r.stdout
    assert "pkcs11:object=label" not in r.stdout
