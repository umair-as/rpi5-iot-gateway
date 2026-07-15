"""Pytest fixtures for sign_fit.py tests.

SoftHSM fixtures mirror the patterns from
meta-openembedded/meta-oe/classes/signing.bbclass (workspace-isolated
SOFTHSM2_CONF + tokendir, `db` backend, `--free` slot init) but stay
independent of any Yocto/BitBake infrastructure — the host runs them
directly via pytest.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
from typing import Optional

import pytest

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent.parent
SIGN_FIT_PY = SCRIPTS_DIR / "sign_fit.py"

SOFTHSM_TOKEN_LABEL = "iotgw-fit-test"
SOFTHSM_PIN = "1234"
SOFTHSM_SO_PIN = "123456"
SOFTHSM_KEY_LABEL = "iotgw-fit-softhsm-dev"

# Module path candidates. IOTGW_SOFTHSM_MODULE env var takes precedence
# so a developer running against a locally-built SoftHSM 2.7.0 can
# point the tests at it without editing files.
SOFTHSM_MODULE_CANDIDATES = (
    "/usr/lib/softhsm/libsofthsm2.so",
    "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so",
    "/usr/lib/aarch64-linux-gnu/softhsm/libsofthsm2.so",
)

# OpenSSL engine_pkcs11 candidates (Debian/Ubuntu 22.04+ ships in engines-3/).
ENGINE_PKCS11_CANDIDATES = (
    "/usr/lib/x86_64-linux-gnu/engines-3/pkcs11.so",
    "/usr/lib/aarch64-linux-gnu/engines-3/pkcs11.so",
)


def _find_module(env_var: str, candidates: tuple[str, ...]) -> Optional[str]:
    env_val = os.environ.get(env_var, "").strip()
    if env_val:
        return env_val if pathlib.Path(env_val).is_file() else None
    for c in candidates:
        if pathlib.Path(c).is_file():
            return c
    return None


def _softhsm_module() -> Optional[str]:
    return _find_module("IOTGW_SOFTHSM_MODULE", SOFTHSM_MODULE_CANDIDATES)


def _engine_pkcs11_module() -> Optional[str]:
    return _find_module("IOTGW_ENGINE_PKCS11", ENGINE_PKCS11_CANDIDATES)


def _softhsm_available() -> bool:
    if os.environ.get("SOFTHSM_AVAILABLE", "").strip() == "0":
        return False
    return (
        shutil.which("softhsm2-util") is not None
        and shutil.which("pkcs11-tool") is not None
        and _softhsm_module() is not None
        and _engine_pkcs11_module() is not None
    )


@pytest.fixture(scope="session")
def softhsm_workspace(tmp_path_factory):
    """Isolated SoftHSM workspace — fresh token store per pytest session.

    Skips the entire test if SoftHSM/engine_pkcs11 aren't usable. The
    fixture leaves SOFTHSM2_CONF and the tokendir under tmp; pytest's
    tmp_path_factory handles teardown.
    """
    if not _softhsm_available():
        pytest.skip(
            "SoftHSM/engine_pkcs11 not available — install softhsm2 + "
            "libengine-pkcs11-openssl, or set SOFTHSM_AVAILABLE=0 to skip"
        )

    work = tmp_path_factory.mktemp("softhsm")
    conf = work / "softhsm2.conf"
    tokens = work / "tokens"
    tokens.mkdir()
    # `file` backend works on the distro SoftHSM 2.6.1 builds shipped
    # by Debian/Ubuntu/Fedora. `db` requires SQLite compiled in, which
    # the distro packages typically don't ship — only meta-oe's
    # softhsm-native enables it.
    conf.write_text(
        f"directories.tokendir = {tokens}\nobjectstore.backend = file\n"
    )

    module = _softhsm_module()
    env = {**os.environ, "SOFTHSM2_CONF": str(conf)}

    subprocess.run(
        [
            "softhsm2-util",
            "--module", module,
            "--init-token", "--free",
            "--label", SOFTHSM_TOKEN_LABEL,
            "--pin", SOFTHSM_PIN,
            "--so-pin", SOFTHSM_SO_PIN,
        ],
        check=True,
        env=env,
        capture_output=True,
    )

    return {
        "conf": conf,
        "module": module,
        "engine_pkcs11_module": _engine_pkcs11_module(),
        "token_label": SOFTHSM_TOKEN_LABEL,
        "pin": SOFTHSM_PIN,
        "so_pin": SOFTHSM_SO_PIN,
        "work": work,
        "env": {"SOFTHSM2_CONF": str(conf)},
    }


@pytest.fixture(scope="session")
def softhsm_dev_key(softhsm_workspace):
    """Generate iotgw-fit-softhsm-dev RSA-2048 keypair + self-signed cert.

    Builds an OpenSSL engine_pkcs11 config pointing at the workspace's
    SoftHSM module and uses it to self-sign a cert against the
    on-token key. The result is what the kernel-fit recipe's
    fdt_add_pubkey step would consume (`<keydir>/<keyname>.crt`).
    """
    env = {**os.environ, **softhsm_workspace["env"]}
    work = softhsm_workspace["work"]

    subprocess.run(
        [
            "pkcs11-tool",
            "--module", softhsm_workspace["module"],
            "--token-label", softhsm_workspace["token_label"],
            "--login", "--pin", softhsm_workspace["pin"],
            "--keypairgen", "--key-type", "rsa:2048",
            "--label", SOFTHSM_KEY_LABEL,
            "--id", "01",
        ],
        check=True,
        env=env,
        capture_output=True,
    )

    engine_conf = work / "openssl-engine.cnf"
    engine_conf.write_text(
        textwrap.dedent(
            f"""\
            openssl_conf = openssl_init

            [openssl_init]
            engines = engine_section

            [engine_section]
            pkcs11 = pkcs11_section

            [pkcs11_section]
            engine_id = pkcs11
            dynamic_path = {softhsm_workspace["engine_pkcs11_module"]}
            MODULE_PATH = {softhsm_workspace["module"]}
            init = 0
            """
        )
    )

    cert_dir = work / "fit"
    cert_dir.mkdir(exist_ok=True)
    cert_path = cert_dir / f"{SOFTHSM_KEY_LABEL}.crt"
    sign_uri = (
        f"pkcs11:token={softhsm_workspace['token_label']};"
        f"object={SOFTHSM_KEY_LABEL};type=private;"
        f"pin-value={softhsm_workspace['pin']}"
    )
    subprocess.run(
        [
            "openssl", "req", "-new", "-x509",
            "-engine", "pkcs11", "-keyform", "engine",
            "-key", sign_uri,
            "-days", "3650",
            "-subj", f"/CN={SOFTHSM_KEY_LABEL}/O=iotgw-test",
            "-out", str(cert_path),
        ],
        check=True,
        env={**env, "OPENSSL_CONF": str(engine_conf)},
        capture_output=True,
    )

    # Profile config the Python tool can load with --profile-config.
    # Embed the PIN inline via pin-value= so the test doesn't prompt.
    profile_uri = (
        f"pkcs11:token={softhsm_workspace['token_label']};"
        f"object={SOFTHSM_KEY_LABEL};pin-value={softhsm_workspace['pin']}"
    )
    profile_config = work / "test-profiles.yml"
    profile_config.write_text(
        textwrap.dedent(
            f"""\
            fit_signing_profiles:
              softhsm-test:
                key_name_hint: "{SOFTHSM_KEY_LABEL}"
                uri: "{profile_uri}"
                engine_conf: "{engine_conf}"
            """
        )
    )

    return {
        "key_label": SOFTHSM_KEY_LABEL,
        "cert_path": cert_path,
        "engine_conf": engine_conf,
        "profile_config": profile_config,
        "uri": profile_uri,
        "env": env,
    }


# ---------------------------------------------------------------------------
# Fixture FIT generation
# ---------------------------------------------------------------------------


FIXTURE_ITS = """\
/dts-v1/;
/ {
    description = "test fixture FIT";
    #address-cells = <1>;

    images {
        kernel-1 {
            description = "kernel";
            data = /incbin/("kernel.bin");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            load = <0x80000>;
            entry = <0x80000>;
            hash-1 {
                algo = "sha256";
            };
        };
        fdt-1 {
            description = "dtb";
            data = /incbin/("dummy.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            hash-1 {
                algo = "sha256";
            };
        };
    };

    configurations {
        default = "conf-1";
        conf-1 {
            description = "conf-1";
            kernel = "kernel-1";
            fdt = "fdt-1";
            signature-1 {
                algo = "sha256,rsa2048";
                key-name-hint = "placeholder";
                sign-images = "kernel", "fdt";
            };
        };
    };
};
"""

FIXTURE_DTS = """\
/dts-v1/;
/ {
    compatible = "test,fixture";
    #address-cells = <1>;
    #size-cells = <0>;
    chosen { };
};
"""


def _build_fixture_dtb(work: pathlib.Path) -> pathlib.Path:
    """Compile FIXTURE_DTS into a tiny DTB at work/dummy.dtb."""
    dts = work / "dummy.dts"
    dtb = work / "dummy.dtb"
    dts.write_text(FIXTURE_DTS)
    subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)],
        check=True,
        capture_output=True,
    )
    return dtb


@pytest.fixture
def fixture_fit(tmp_path):
    """Build a fresh fitImage in tmp_path for each test that needs one."""
    (tmp_path / "kernel.bin").write_bytes(b"\xAA" * 1024)
    _build_fixture_dtb(tmp_path)
    its = tmp_path / "test.its"
    its.write_text(FIXTURE_ITS)
    fit = tmp_path / "fitImage"
    subprocess.run(
        ["mkimage", "-f", str(its), str(fit)],
        check=True,
        cwd=str(tmp_path),
        capture_output=True,
    )
    return fit


@pytest.fixture
def fixture_dtb_with_pubkey(tmp_path, softhsm_dev_key):
    """A DTB that trusts the SoftHSM dev pubkey — for fit_check_sign verify.

    Uses fdt_add_pubkey to inject the dev cert into a fresh DTB so the
    verify subcommand has a trust root to check the signed FIT against.
    """
    fit_check_dtb = tmp_path / "trust.dtb"
    # Start from the same minimal DTS.
    dts = tmp_path / "trust.dts"
    dts.write_text(FIXTURE_DTS)
    subprocess.run(
        ["dtc", "-I", "dts", "-O", "dtb", "-o", str(fit_check_dtb), str(dts)],
        check=True,
        capture_output=True,
    )

    cert_dir = softhsm_dev_key["cert_path"].parent
    fdt_add_pubkey = _find_fdt_add_pubkey()
    if fdt_add_pubkey is None:
        pytest.skip(
            "fdt_add_pubkey not found on host or in build sysroot; "
            "set IOTGW_FIT_CHECK_SIGN/PATH or build u-boot-tools-native first"
        )
    subprocess.run(
        [
            fdt_add_pubkey,
            "-a", "sha256,rsa2048",
            "-k", str(cert_dir),
            "-n", softhsm_dev_key["key_label"],
            "-r", "conf",
            str(fit_check_dtb),
        ],
        check=True,
        capture_output=True,
    )
    return fit_check_dtb


_SYSROOT_GLOBS = (
    "build/tmp-glibc/sysroots-components/x86_64/u-boot-tools-native/"
    "usr/bin/{tool}",
    "build/tmp-glibc/work/x86_64-linux/u-boot-tools-native/*/"
    "recipe-sysroot-native/usr/bin/{tool}",
)


def _find_in_build_sysroot(tool: str) -> Optional[str]:
    project_root = pathlib.Path.cwd()
    for tmpl in _SYSROOT_GLOBS:
        for c in sorted(project_root.glob(tmpl.format(tool=tool))):
            if c.is_file():
                return str(c)
    return None


def _find_fdt_add_pubkey() -> Optional[str]:
    """Mirror sign_fit.py's discovery: PATH → env → project build sysroot."""
    env = os.environ.get("IOTGW_FDT_ADD_PUBKEY", "").strip()
    if env and pathlib.Path(env).is_file():
        return env
    on_path = shutil.which("fdt_add_pubkey")
    if on_path:
        return on_path
    return _find_in_build_sysroot("fdt_add_pubkey")


def _find_fit_check_sign() -> Optional[str]:
    """Equivalent discovery for fit_check_sign."""
    env = os.environ.get("IOTGW_FIT_CHECK_SIGN", "").strip()
    if env and pathlib.Path(env).is_file():
        return env
    on_path = shutil.which("fit_check_sign")
    if on_path:
        return on_path
    return _find_in_build_sysroot("fit_check_sign")


@pytest.fixture
def fit_check_sign_tool() -> str:
    tool = _find_fit_check_sign()
    if tool is None:
        pytest.skip(
            "fit_check_sign not found on host or in build sysroot; "
            "build u-boot-tools-native or set IOTGW_FIT_CHECK_SIGN"
        )
    return tool


# ---------------------------------------------------------------------------
# Shared command runner
# ---------------------------------------------------------------------------


def run_sign_fit(*args: str, env: Optional[dict] = None, check: bool = True) -> subprocess.CompletedProcess:
    """Invoke the Python tool as a subprocess, returning the completed process."""
    return subprocess.run(
        [sys.executable, str(SIGN_FIT_PY), *args],
        env={**os.environ, **(env or {})},
        capture_output=True,
        text=True,
        check=check,
    )
