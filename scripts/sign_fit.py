#!/usr/bin/env python3
"""sign_fit.py — sign U-Boot FIT images via mkimage + engine_pkcs11.

Subcommands:
    sign-fit         Sign a raw fitImage in place.
    sign-bootfiles   Sign the fitImage inside a bootfiles-fit.tar.gz archive.
    verify           fit_check_sign cryptographic verify against a DTB.
    print-profile    Print a resolved profile (diagnostic; no signing).

Profiles live in `scripts/fit-signing-profiles.yml` (or the file pointed
at by --profile-config / IOTGW_FIT_SIGNING_PROFILES). Each profile maps a
short name (yubikey-9a, softhsm-dev) to a (key-name-hint, URI, engine
config) tuple. Explicit --key-name-hint / --uri / --engine-conf flags
override the profile.

mkimage 2025.04 quirks worked around here:
  - `-G` is silently ignored in the `-N pkcs11` code path; the tool
    always uses `-k <URI>` with a URI that must contain `object=`.
  - `mkimage -F -N pkcs11 <fit>` without a working keydir is a silent
    no-op (FIT repacked, signature bytes intact). This tool requires at
    least one `Signature written` line in mkimage's output before
    declaring success.

Slot-anchored URIs (pkcs11:id=...) are out of scope — they require a
signer that calls OpenSSL directly rather than through mkimage's
-N pkcs11 path.
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
from typing import Iterable, Optional, Sequence

try:
    import yaml
except ImportError as e:
    sys.stderr.write(
        "sign_fit: PyYAML is required (Debian/Ubuntu: apt install python3-yaml; "
        "Fedora: dnf install python3-pyyaml; pip: pip install pyyaml)\n"
    )
    raise

log = logging.getLogger("sign_fit")

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_PROFILE_CONFIG = SCRIPT_DIR / "fit-signing-profiles.yml"
DEFAULT_BOOTFILES_ARCHIVE = pathlib.Path(
    "build/tmp-glibc/deploy/images/raspberrypi5/bootfiles-fit.tar.gz"
)


class SignFitError(Exception):
    """Raised for any user-visible failure."""


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    log.error(msg)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Profile loading
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Profile:
    name: str
    key_name_hint: str
    uri: str
    engine_conf: pathlib.Path

    @classmethod
    def from_dict(cls, name: str, d: dict, *, engine_conf_override: Optional[pathlib.Path] = None) -> "Profile":
        try:
            engine_conf = engine_conf_override or pathlib.Path(
                os.path.expanduser(d["engine_conf"])
            )
            return cls(
                name=name,
                key_name_hint=d["key_name_hint"],
                uri=d["uri"],
                engine_conf=engine_conf,
            )
        except KeyError as e:
            raise SignFitError(
                f"profile '{name}' missing required field: {e.args[0]}"
            ) from e


def resolve_profile_config(cli_path: Optional[str]) -> pathlib.Path:
    if cli_path:
        return pathlib.Path(os.path.expanduser(cli_path))
    env = os.environ.get("IOTGW_FIT_SIGNING_PROFILES")
    if env:
        return pathlib.Path(os.path.expanduser(env))
    return DEFAULT_PROFILE_CONFIG


def load_profiles(config_path: pathlib.Path) -> dict[str, dict]:
    if not config_path.is_file():
        raise SignFitError(f"profile config not found: {config_path}")
    with config_path.open("r") as f:
        try:
            data = yaml.safe_load(f) or {}
        except yaml.YAMLError as e:
            raise SignFitError(f"YAML parse error in {config_path}: {e}") from e
    profiles = data.get("fit_signing_profiles", {})
    if not profiles:
        raise SignFitError(
            f"no fit_signing_profiles entries in {config_path}"
        )
    return profiles


def build_profile(
    *,
    name: Optional[str],
    config_path: pathlib.Path,
    key_name_hint_override: Optional[str],
    uri_override: Optional[str],
    engine_conf_override: Optional[str],
    key_label_legacy: Optional[str] = None,
) -> Profile:
    """Resolve a profile from config + per-flag overrides.

    If --profile is not given, all three of --key-name-hint / --uri /
    --engine-conf must be supplied explicitly. --key-label is a
    deprecated alias that pre-dates the hint/URI split: it sets the
    FIT key-name-hint AND, if --uri is not supplied, derives the URI
    as pkcs11:object=<urlencoded label>. Combining --key-label with
    --key-name-hint is a fatal error.
    """
    if key_label_legacy is not None:
        log.warning(
            "--key-label is deprecated; use --key-name-hint (and --uri) explicitly"
        )
        if key_name_hint_override is not None:
            raise SignFitError(
                "--key-label and --key-name-hint are mutually exclusive"
            )
        key_name_hint_override = key_label_legacy
        if uri_override is None:
            uri_override = (
                "pkcs11:object=" + urllib.parse.quote(key_label_legacy, safe="")
            )

    if name:
        profiles = load_profiles(config_path)
        if name not in profiles:
            available = ", ".join(sorted(profiles.keys())) or "(none)"
            raise SignFitError(
                f"unknown profile: {name!r}; available: {available}"
            )
        engine_conf = (
            pathlib.Path(os.path.expanduser(engine_conf_override))
            if engine_conf_override
            else None
        )
        base = Profile.from_dict(name, profiles[name], engine_conf_override=engine_conf)
    else:
        missing = [
            flag
            for flag, val in [
                ("--key-name-hint", key_name_hint_override),
                ("--uri", uri_override),
                ("--engine-conf", engine_conf_override),
            ]
            if not val
        ]
        if missing:
            raise SignFitError(
                "either --profile or all of "
                "--key-name-hint/--uri/--engine-conf are required; missing: "
                + ", ".join(missing)
            )
        base = Profile(
            name="(explicit)",
            key_name_hint=key_name_hint_override,
            uri=uri_override,
            engine_conf=pathlib.Path(os.path.expanduser(engine_conf_override)),
        )

    # Per-flag overrides on top of profile values
    return Profile(
        name=base.name,
        key_name_hint=key_name_hint_override or base.key_name_hint,
        uri=uri_override or base.uri,
        engine_conf=(
            pathlib.Path(os.path.expanduser(engine_conf_override))
            if engine_conf_override
            else base.engine_conf
        ),
    )


def validate_profile(profile: Profile, *, require_engine_conf: bool = True) -> None:
    if "object=" not in profile.uri:
        raise SignFitError(
            f"URI must contain 'object=<libykcs11-label>' "
            f"(mkimage 2025.04's -N pkcs11 path rewrites URIs without object= "
            f"into a non-matching synthesized URI). got: {profile.uri}"
        )
    if not profile.uri.startswith("pkcs11:"):
        raise SignFitError(f"URI must start with 'pkcs11:': {profile.uri}")
    if require_engine_conf and not profile.engine_conf.is_file():
        raise SignFitError(f"engine conf not found: {profile.engine_conf}")


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SignFitError(f"required tool missing on PATH: {name}")
    return path


def find_fit_check_sign(cli_path: Optional[str]) -> str:
    if cli_path:
        if not pathlib.Path(cli_path).is_file():
            raise SignFitError(
                f"fit_check_sign not at --fit-check-sign-path: {cli_path}"
            )
        return cli_path
    env = os.environ.get("IOTGW_FIT_CHECK_SIGN")
    if env:
        if not pathlib.Path(env).is_file():
            raise SignFitError(
                f"fit_check_sign not at IOTGW_FIT_CHECK_SIGN: {env}"
            )
        return env
    on_path = shutil.which("fit_check_sign")
    if on_path:
        return on_path

    # Project-local discovery: the build sysroot installs fit_check_sign
    # via meta-iot-gateway's u-boot-tools_%.bbappend. Walk the most
    # common project-build paths.
    project_root = pathlib.Path.cwd()
    candidates: list[pathlib.Path] = []
    candidates.extend(
        sorted(
            project_root.glob(
                "build/tmp-glibc/work/x86_64-linux/u-boot-tools-native/*/"
                "recipe-sysroot-native/usr/bin/fit_check_sign"
            )
        )
    )
    candidates.extend(
        sorted(
            project_root.glob(
                "build/tmp-glibc/sysroots-components/x86_64/u-boot-tools-native/"
                "usr/bin/fit_check_sign"
            )
        )
    )
    for c in candidates:
        if c.is_file():
            return str(c)

    raise SignFitError(
        "fit_check_sign not found. Install u-boot-tools that ship it, "
        "or point to the project build sysroot:\n"
        "  export IOTGW_FIT_CHECK_SIGN=$(find build -name fit_check_sign | head -1)"
    )


# ---------------------------------------------------------------------------
# FIT signing
# ---------------------------------------------------------------------------


def _list_subnodes(fit: pathlib.Path, node: str) -> list[str]:
    """fdtget -l <fit> <node> as a list of children names."""
    fdtget = require_tool("fdtget")
    result = subprocess.run(
        [fdtget, "-l", str(fit), node],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SignFitError(
            f"fdtget -l failed on {node}: {result.stderr.strip()}"
        )
    return [line for line in result.stdout.splitlines() if line.strip()]


def _rewrite_key_name_hints(fit: pathlib.Path, key_name_hint: str) -> int:
    """Walk /configurations/*/signature* and set key-name-hint. Returns count."""
    fdtput = require_tool("fdtput")
    confs = _list_subnodes(fit, "/configurations")
    if not confs:
        raise SignFitError(f"no /configurations subnodes in {fit}")
    total = 0
    for conf in confs:
        children = _list_subnodes(fit, f"/configurations/{conf}")
        sig_count = 0
        for child in children:
            if not child.startswith("signature"):
                continue
            path = f"/configurations/{conf}/{child}"
            r = subprocess.run(
                [fdtput, "-t", "s", str(fit), path, "key-name-hint", key_name_hint],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                raise SignFitError(
                    f"fdtput failed on {path}: {r.stderr.strip()}"
                )
            sig_count += 1
            total += 1
        if sig_count == 0:
            raise SignFitError(
                f"no signature* nodes under /configurations/{conf}"
            )
    log.info(
        "rewrote key-name-hint to %r on %d signature node(s) across %d configuration(s)",
        key_name_hint,
        total,
        len(confs),
    )
    return total


def _run_mkimage_sign(fit: pathlib.Path, profile: Profile, *, verbose: bool) -> int:
    """Invoke mkimage -F -N pkcs11 -k <URI> <fit>. Returns number of `Signature written` lines."""
    mkimage = require_tool("mkimage")
    log.info("signing FIT via engine_pkcs11 (PIN/touch may be required)")
    log.info("  URI: %s", profile.uri)

    env = os.environ.copy()
    env["OPENSSL_CONF"] = str(profile.engine_conf)

    # U-Boot 2025.04 ignores -G/keyfile in the pkcs11 RSA path.
    # Passing -k pkcs11:object=<label> is the only way to decouple
    # private-key lookup from the FIT key-name-hint.
    cmd = [mkimage, "-F", "-N", "pkcs11", "-k", profile.uri, str(fit)]

    # Always capture mkimage output. PIN prompts from engine_pkcs11 are
    # written by OpenSSL's UI to /dev/tty and bypass stdout/stderr
    # redirection, so capturing here does not silence the PIN prompt.
    # Capturing is mandatory for the silent-no-op guard (the
    # `Signature written` line is the authoritative success signal).
    # In verbose mode we additionally tee the captured output to stderr
    # so the operator sees what mkimage produced.
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)

    if verbose:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)

    def _dump_for_diagnostics() -> None:
        # When --verbose already showed the output, skip the framed
        # second copy to keep the terminal readable.
        if verbose:
            return
        sys.stderr.write("---- mkimage output ----\n")
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.stderr.write("------------------------\n")

    if result.returncode != 0:
        _dump_for_diagnostics()
        raise SignFitError(f"mkimage -F failed (exit {result.returncode})")

    sig_written = sum(1 for line in result.stdout.splitlines() if "Signature written" in line)
    if sig_written == 0:
        _dump_for_diagnostics()
        raise SignFitError(
            "mkimage exited 0 but emitted no 'Signature written' line — "
            "signing was a silent no-op (check engine config and that -k "
            "carries a 'pkcs11:object=<label>' URI)"
        )
    log.info("mkimage signed (%d 'Signature written' line(s) observed)", sig_written)
    return sig_written


def _structural_verify(fit: pathlib.Path, profile: Profile, total_sigs: int) -> str:
    """Replicate sign-fit.sh's --verify check: dumpimage -l audit on each sig node."""
    dumpimage = require_tool("dumpimage")
    expected_algo = f"sha256,rsa2048:{profile.key_name_hint}"
    result = subprocess.run(
        [dumpimage, "-l", str(fit)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SignFitError(
            f"dumpimage failed during verify: {result.stderr.strip()}"
        )
    out = result.stdout
    algo_lines = [l for l in out.splitlines() if "Sign algo:" in l]
    match_count = sum(1 for l in algo_lines if expected_algo in l)
    if len(algo_lines) < total_sigs or match_count < total_sigs:
        sys.stderr.write(out)
        raise SignFitError(
            f"verify failed: expected {total_sigs} signature(s) with algo "
            f"{expected_algo!r}, found {match_count}"
        )
    bad_sigs = 0
    for line in out.splitlines():
        if "Sign value:" in line:
            val = line.split("Sign value:", 1)[1].strip()
            if not val or val == "unavailable":
                bad_sigs += 1
    if bad_sigs:
        sys.stderr.write(out)
        raise SignFitError(
            f"verify failed: {bad_sigs} signature node(s) have empty or 'unavailable' Sign value"
        )
    msg = f"PASS ({match_count} signature(s) matched {expected_algo!r})"
    log.info("verify: %s", msg)
    return msg


def sign_fit_file(
    fit: pathlib.Path,
    profile: Profile,
    *,
    verify: bool,
    rewrite_only: bool,
    verbose: bool,
) -> dict:
    """Top-level: backup, rewrite hints, sign, optional verify. Returns summary dict."""
    if not fit.is_file():
        raise SignFitError(f"fitImage not found: {fit}")
    if not os.access(fit, os.W_OK):
        raise SignFitError(f"fitImage not writable: {fit}")
    fit_dir = fit.parent
    if not os.access(fit_dir, os.W_OK):
        raise SignFitError(f"cannot write backup next to {fit} (directory not writable)")

    # Tool presence checks for the planned operation set.
    for tool in ("fdtget", "fdtput", "mkimage"):
        require_tool(tool)
    if not rewrite_only or verify:
        require_tool("dumpimage")

    backup = fit.with_suffix(fit.suffix + ".bak")
    shutil.copy2(fit, backup)
    mutated = False
    try:
        total_sigs = _rewrite_key_name_hints(fit, profile.key_name_hint)
        mutated = True

        verify_result = "skipped"
        if rewrite_only:
            log.info("rewrite-only: FIT key-name-hint rewritten in place; skipping mkimage")
            mode = "rewrite-only (FIT mutated, mkimage skipped)"
        else:
            _run_mkimage_sign(fit, profile, verbose=verbose)
            mode = "signed via engine_pkcs11"
            if verify:
                verify_result = _structural_verify(fit, profile, total_sigs)

        return {
            "fit": str(fit),
            "key_name_hint": profile.key_name_hint,
            "uri": profile.uri,
            "engine_conf": str(profile.engine_conf),
            "configurations": len(_list_subnodes(fit, "/configurations")),
            "signature_nodes": total_sigs,
            "mode": mode,
            "verify": verify_result,
        }
    except Exception:
        if mutated and backup.is_file():
            try:
                shutil.copy2(backup, fit)
                log.warning("restored %s from %s after failure", fit, backup)
            except Exception as restore_err:
                log.error(
                    "FAILED to restore %s from %s — inspect manually: %s",
                    fit,
                    backup,
                    restore_err,
                )
        raise
    finally:
        backup.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# bootfiles-fit.tar.gz handling
# ---------------------------------------------------------------------------


def _sha256(p: pathlib.Path) -> str:
    import hashlib

    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _peek_inner_fit_algo_status(
    archive: pathlib.Path, expected_algo: str
) -> tuple[int, int]:
    """Return (total_algo_lines, matching_count) without mutating the archive."""
    dumpimage = require_tool("dumpimage")
    with tempfile.TemporaryDirectory(prefix="sign-bootfiles-peek-") as td:
        try:
            with tarfile.open(archive, "r:gz") as tf:
                try:
                    # `filter='data'` rejects absolute paths, .. traversal,
                    # special files, etc. — Python 3.12+ tarfile safety
                    # default (PEP 706).
                    tf.extract("./fitImage", td, filter="data")
                except KeyError:
                    return (0, 0)
        except tarfile.TarError:
            return (0, 0)
        fit_path = pathlib.Path(td) / "fitImage"
        if not fit_path.is_file():
            return (0, 0)
        result = subprocess.run(
            [dumpimage, "-l", str(fit_path)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return (0, 0)
        algo_lines = [l for l in result.stdout.splitlines() if "Sign algo:" in l]
        return (len(algo_lines), sum(1 for l in algo_lines if expected_algo in l))


def sign_bootfiles_archive(
    archive: pathlib.Path,
    profile: Profile,
    *,
    force: bool,
    verify: bool,
    verbose: bool,
) -> dict:
    """Extract → sign inner FIT → repack."""
    if not archive.is_file():
        raise SignFitError(f"archive not found: {archive}")
    if not os.access(archive, os.W_OK):
        raise SignFitError(f"archive not writable: {archive}")
    archive = archive.resolve()
    archive_dir = archive.parent
    if not os.access(archive_dir, os.W_OK):
        raise SignFitError(f"archive directory not writable: {archive_dir}")

    require_tool("tar")
    require_tool("dumpimage")

    expected_algo = f"sha256,rsa2048:{profile.key_name_hint}"
    pre_sha = _sha256(archive)
    log.info("archive: %s", archive)
    log.info("pre  sha256: %s", pre_sha)

    if not force:
        total, match = _peek_inner_fit_algo_status(archive, expected_algo)
        if total > 0 and match == total:
            log.info(
                "all %d signature node(s) in inner FIT already labelled %r; "
                "skipping (use --force to re-sign)",
                total,
                expected_algo,
            )
            return {
                "archive": str(archive),
                "pre_sha": pre_sha,
                "post_sha": pre_sha,
                "inner_fit_algo": expected_algo,
                "inner_fit_total": total,
                "mode": "skipped (already labelled)",
            }
        if total > 0 and 0 < match < total:
            log.info(
                "inner FIT is partially labelled (%d of %d match %r); "
                "proceeding to re-sign all",
                match,
                total,
                expected_algo,
            )

    backup = archive.with_suffix(archive.suffix + ".bak")
    shutil.copy2(archive, backup)
    mutated = False
    tmpdir = tempfile.mkdtemp(prefix="sign-bootfiles-fit.")
    try:
        log.info("extracting into %s", tmpdir)
        with tarfile.open(archive, "r:gz") as tf:
            # `filter='data'` is PEP 706's safe default: rejects
            # absolute paths, parent-dir traversal, devices, setuid,
            # symlinks pointing outside the destination. The bootfiles
            # archive is Yocto-produced and trusted, but the filter
            # costs nothing and protects against future supply-chain
            # surprises.
            tf.extractall(tmpdir, filter="data")
        extracted_fit = pathlib.Path(tmpdir) / "fitImage"
        if not extracted_fit.is_file():
            raise SignFitError(f"fitImage not found in archive (looked at {extracted_fit})")

        log.info("invoking signing on extracted fitImage")
        mutated = True
        sign_fit_file(
            extracted_fit,
            profile,
            verify=verify,
            rewrite_only=False,
            verbose=verbose,
        )

        log.info("repacking %s", archive)
        new_archive = archive.with_suffix(archive.suffix + ".new")
        # Match the original layout (entries start with `./`).
        with tarfile.open(new_archive, "w:gz") as tf:
            for entry in sorted(pathlib.Path(tmpdir).iterdir()):
                tf.add(entry, arcname=f"./{entry.name}")
        new_archive.replace(archive)

        post_sha = _sha256(archive)
        log.info("post sha256: %s", post_sha)
        if pre_sha == post_sha:
            raise SignFitError(
                "archive SHA unchanged after repack — signing likely no-op'd"
            )

        return {
            "archive": str(archive),
            "pre_sha": pre_sha,
            "post_sha": post_sha,
            "inner_fit_algo": expected_algo,
            "mode": "signed",
        }
    except Exception:
        if mutated and backup.is_file():
            try:
                shutil.copy2(backup, archive)
                log.warning("restored %s from %s after failure", archive, backup)
            except Exception as restore_err:
                log.error(
                    "FAILED to restore %s from %s — inspect manually: %s",
                    archive,
                    backup,
                    restore_err,
                )
        raise
    finally:
        backup.unlink(missing_ok=True)
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# fit_check_sign verify
# ---------------------------------------------------------------------------


def crypto_verify_fit(fit: pathlib.Path, dtb: pathlib.Path, *, tool: str) -> dict:
    """Run fit_check_sign -f <fit> -k <dtb> for real RSA verify."""
    if not fit.is_file():
        raise SignFitError(f"fitImage not found: {fit}")
    if not dtb.is_file():
        raise SignFitError(f"DTB not found: {dtb}")

    log.info("crypto-verifying %s against %s", fit, dtb)
    log.info("  fit_check_sign: %s", tool)
    result = subprocess.run(
        [tool, "-f", str(fit), "-k", str(dtb)],
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        sys.stderr.write(output)
        raise SignFitError(f"fit_check_sign failed (exit {result.returncode})")
    log.info("verify: PASS")
    return {
        "fit": str(fit),
        "dtb": str(dtb),
        "tool": tool,
        "output": output.strip(),
        "result": "PASS",
    }


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------


def _print_summary(title: str, fields: dict) -> None:
    sys.stdout.write("\n")
    sys.stdout.write(f"================ {title} ================\n")
    for k, v in fields.items():
        sys.stdout.write(f"  {k:<16}: {v}\n")
    sys.stdout.write("=" * (len(title) + 34) + "\n")


def cmd_sign_fit(args: argparse.Namespace) -> int:
    config_path = resolve_profile_config(args.profile_config)
    profile = build_profile(
        name=args.profile,
        config_path=config_path,
        key_name_hint_override=args.key_name_hint,
        uri_override=args.uri,
        engine_conf_override=args.engine_conf,
        key_label_legacy=args.key_label,
    )
    validate_profile(profile, require_engine_conf=not args.rewrite_only)
    summary = sign_fit_file(
        pathlib.Path(args.fit),
        profile,
        verify=args.verify,
        rewrite_only=args.rewrite_only,
        verbose=args.verbose,
    )
    _print_summary("sign-fit summary", summary)
    return 0


def cmd_sign_bootfiles(args: argparse.Namespace) -> int:
    config_path = resolve_profile_config(args.profile_config)
    profile = build_profile(
        name=args.profile,
        config_path=config_path,
        key_name_hint_override=args.key_name_hint,
        uri_override=args.uri,
        engine_conf_override=args.engine_conf,
        key_label_legacy=args.key_label,
    )
    validate_profile(profile, require_engine_conf=True)
    archive = pathlib.Path(args.archive) if args.archive else DEFAULT_BOOTFILES_ARCHIVE
    summary = sign_bootfiles_archive(
        archive,
        profile,
        force=args.force,
        verify=args.verify,
        verbose=args.verbose,
    )
    _print_summary("sign-bootfiles summary", summary)
    if "post_sha" in summary and summary["post_sha"] != summary["pre_sha"]:
        sys.stdout.write(
            "\nNext step: re-drive the bundle recipe so it picks up the new\n"
            "tarball. With this project's KAS+make wrapper, that is:\n"
            "  make bundle-dev-full-fit-resign\n"
        )
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    tool = find_fit_check_sign(args.fit_check_sign_path)
    summary = crypto_verify_fit(
        pathlib.Path(args.fit),
        pathlib.Path(args.dtb),
        tool=tool,
    )
    _print_summary("verify summary", summary)
    return 0


def cmd_print_profile(args: argparse.Namespace) -> int:
    config_path = resolve_profile_config(args.profile_config)
    profile = build_profile(
        name=args.profile,
        config_path=config_path,
        key_name_hint_override=args.key_name_hint,
        uri_override=args.uri,
        engine_conf_override=args.engine_conf,
        key_label_legacy=args.key_label,
    )
    # Don't validate engine_conf existence here; --print-profile is a
    # diagnostic and may be useful even when the engine config is
    # not yet on disk.
    sys.stdout.write(f"profile        : {profile.name}\n")
    sys.stdout.write(f"key_name_hint  : {profile.key_name_hint}\n")
    sys.stdout.write(f"uri            : {profile.uri}\n")
    sys.stdout.write(f"engine_conf    : {profile.engine_conf}\n")
    sys.stdout.write(f"config_source  : {config_path}\n")
    return 0


# ---------------------------------------------------------------------------
# Argparse wiring
# ---------------------------------------------------------------------------


def _add_profile_args(sp: argparse.ArgumentParser) -> None:
    sp.add_argument(
        "--profile",
        help="Signing profile name from the profile config (e.g. yubikey-9a, softhsm-dev).",
    )
    sp.add_argument(
        "--profile-config",
        help=(
            "Path to a YAML profile file. Defaults to scripts/fit-signing-profiles.yml "
            "or $IOTGW_FIT_SIGNING_PROFILES if set."
        ),
    )
    sp.add_argument(
        "--key-name-hint",
        help="Override profile's FIT key-name-hint.",
    )
    sp.add_argument(
        "--uri",
        help="Override profile's PKCS#11 URI (must contain object=<label>).",
    )
    sp.add_argument(
        "--engine-conf",
        help="Override profile's OpenSSL engine_pkcs11 config path.",
    )
    sp.add_argument(
        "--key-label",
        help=(
            "DEPRECATED alias: sets --key-name-hint and, if --uri is not given, "
            "derives uri=pkcs11:object=<urlencoded NAME>. Mutually exclusive "
            "with --key-name-hint."
        ),
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sign_fit.py",
        description=__doc__.split("\n\n", 1)[0],
    )
    p.add_argument("-v", "--verbose-log", action="store_true", help="Debug logging.")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp_sign = sub.add_parser("sign-fit", help="Sign a raw fitImage in place.")
    _add_profile_args(sp_sign)
    sp_sign.add_argument("--fit", required=True, help="Path to fitImage.")
    sp_sign.add_argument(
        "--verify",
        action="store_true",
        help="Run structural audit (not crypto) after signing.",
    )
    sp_sign.add_argument(
        "--rewrite-only",
        action="store_true",
        help="Rewrite key-name-hint and stop before mkimage. The FIT is still mutated.",
    )
    sp_sign.add_argument(
        "--verbose",
        action="store_true",
        help="Forward mkimage's full stdout to the terminal (disables silent no-op detection).",
    )
    sp_sign.set_defaults(func=cmd_sign_fit)

    sp_arch = sub.add_parser(
        "sign-bootfiles",
        help="Sign the fitImage inside a bootfiles-fit.tar.gz archive.",
    )
    _add_profile_args(sp_arch)
    sp_arch.add_argument(
        "--archive",
        help=f"Path to bootfiles-fit.tar.gz. Default: {DEFAULT_BOOTFILES_ARCHIVE}",
    )
    sp_arch.add_argument(
        "--force",
        action="store_true",
        help="Re-sign even when the inner FIT already advertises the expected algo.",
    )
    sp_arch.add_argument("--verify", action="store_true", help="Structural verify after signing.")
    sp_arch.add_argument("--verbose", action="store_true", help="Forward mkimage stdout.")
    sp_arch.set_defaults(func=cmd_sign_bootfiles)

    sp_verify = sub.add_parser(
        "verify",
        help="Run fit_check_sign for cryptographic verification against a DTB.",
    )
    sp_verify.add_argument("--fit", required=True, help="Path to fitImage.")
    sp_verify.add_argument("--dtb", required=True, help="Path to DTB carrying the pubkey.")
    sp_verify.add_argument(
        "--fit-check-sign-path",
        help="Override the fit_check_sign binary location.",
    )
    sp_verify.set_defaults(func=cmd_verify)

    sp_print = sub.add_parser(
        "print-profile",
        help="Resolve a profile (with overrides) and print it. No signing.",
    )
    _add_profile_args(sp_print)
    sp_print.set_defaults(func=cmd_print_profile)

    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose_log else logging.INFO,
        format="%(name)s: %(message)s",
    )
    try:
        return args.func(args)
    except SignFitError as e:
        log.error("%s", e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
