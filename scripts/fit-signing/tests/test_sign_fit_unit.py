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

# sign_fit.py runs its venv re-exec inside main(), not at import time, so its
# helper functions can be imported and unit-tested directly.
sys.path.insert(0, str(SIGN_FIT_PY.parent))
import sign_fit  # noqa: E402


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
                pkcs11_module: "/tmp/pkcs11.so"
                signer_alias: "SOFTHSM-DEV"
            """
        )
    )
    r = run_sign_fit("print-profile", "--profile", "custom", "--profile-config", str(cfg))
    assert r.returncode == 0
    assert "custom-hint" in r.stdout
    assert "custom-label" in r.stdout
    assert "/tmp/pkcs11.so" in r.stdout
    assert "SOFTHSM-DEV" in r.stdout


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


def test_provenance_redacts_inline_pin(fixture_fit, tmp_path):
    """Provenance JSON should be usable for audit without leaking URI PINs,
    and an inline PIN must draw a loud warning without leaking the PIN."""
    out = tmp_path / "signing-result.json"
    r = run_sign_fit(
        "sign-fit",
        "--fit", str(fixture_fit),
        "--key-name-hint", "audit-hint",
        "--uri", "pkcs11:object=audit-key;pin-value=1234",
        "--engine-conf", "/tmp/none.cnf",
        "--signer-alias", "SOFTHSM-DEV",
        "--rewrite-only",
        "--provenance", str(out),
    )
    assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
    # An inline PIN is warned about, but the warning itself never
    # echoes the raw PIN.
    assert "inline PIN" in r.stderr
    assert "1234" not in r.stderr
    data = json.loads(out.read_text())
    assert data["schema"] == "iotgw.fit-signing-result.v1"
    assert data["signer"]["alias"] == "SOFTHSM-DEV"
    encoded = json.dumps(data)
    assert "pin-value=1234" not in encoded
    assert "pin-value=<redacted>" in encoded


def test_pkcs11_preflight_requires_explicit_module(fixture_fit):
    r = run_sign_fit(
        "sign-fit",
        "--fit", str(fixture_fit),
        "--key-name-hint", "test-key",
        "--uri", "pkcs11:object=test-key",
        "--engine-conf", "/tmp/none.cnf",
        "--rewrite-only",
        "--pkcs11-preflight",
        check=False,
    )
    assert r.returncode == 1
    assert "pkcs11_module" in r.stderr or "--pkcs11-module" in r.stderr


def test_fit_check_sign_discovery_via_env(tmp_path, monkeypatch):
    """verify subcommand respects IOTGW_FIT_CHECK_SIGN override."""
    # Provide a fake binary that doesn't exist; we just want the error
    # to come from there (proves the env var is consulted).
    monkeypatch.setenv("IOTGW_FIT_CHECK_SIGN", "/nonexistent/fit_check_sign")
    r = run_sign_fit("verify", "--fit", "/tmp/x", "--dtb", "/tmp/y", check=False)
    assert r.returncode == 1
    assert "IOTGW_FIT_CHECK_SIGN" in r.stderr or "not at" in r.stderr


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


# ---------------------------------------------------------------------------
# redact_pkcs11_uri matrix — imported directly, no subprocess needed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "uri, expected",
    [
        # lowercase pin-value in the path component
        (
            "pkcs11:object=k;pin-value=1234",
            "pkcs11:object=k;pin-value=<redacted>",
        ),
        # UPPERCASE attribute name must still be caught (IGNORECASE); the
        # substituted token normalizes to the lowercase literal, which is
        # fine — the point is the PIN value is gone.
        (
            "pkcs11:object=k;PIN-VALUE=1234",
            "pkcs11:object=k;pin-value=<redacted>",
        ),
        # mixed-case
        (
            "pkcs11:object=k;Pin-Value=1234",
            "pkcs11:object=k;pin-value=<redacted>",
        ),
        # pin-source in the path component
        (
            "pkcs11:object=k;pin-source=file:/tmp/pin",
            "pkcs11:object=k;pin-source=<redacted>",
        ),
        # query component: value class must stop at '&' so a following
        # attribute (module-path) survives intact
        (
            "pkcs11:object=k?pin-value=1234&module-path=/usr/lib/p11.so",
            "pkcs11:object=k?pin-value=<redacted>&module-path=/usr/lib/p11.so",
        ),
        # no PIN material — returned unchanged
        (
            "pkcs11:object=iotgw-fit-softhsm-dev",
            "pkcs11:object=iotgw-fit-softhsm-dev",
        ),
    ],
)
def test_redact_pkcs11_uri_matrix(uri, expected):
    assert sign_fit.redact_pkcs11_uri(uri) == expected


def test_redact_pkcs11_uri_never_leaks_pin():
    for uri in (
        "pkcs11:object=k;pin-value=SECRET",
        "pkcs11:object=k;PIN-VALUE=SECRET",
        "pkcs11:object=k?pin-value=SECRET&module-path=/p11.so",
    ):
        assert "SECRET" not in sign_fit.redact_pkcs11_uri(uri)
