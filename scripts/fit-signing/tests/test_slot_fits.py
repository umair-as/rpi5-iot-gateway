"""Tests for slot_fits.py and sign_fit.py sign-slot-fits.

Fixtures build the real artifact formats: a small ext4 rootfs with a
superblock-free dm-verity hash tree appended (as meta-oe's verity image type
writes it), two single-configuration FITs whose device trees carry the slot
command lines, and a bootfiles archive holding the trust anchor. FITs are
signed with file keys: "dev" plays the build key and "prof" the operator's
signing key, so the sign/skip/rollback logic runs without an HSM. The last test
drives the CLI against the SoftHSM token.
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import tarfile

import pytest

from conftest import _find_fit_check_sign, run_sign_fit

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "meta-iot-gateway" / "scripts"))
import slot_fits  # noqa: E402

IMAGE = "test-image-machine.rootfs"
DEVICES = {"A": "/dev/mmcblk0p3", "B": "/dev/mmcblk0p4"}
BLOCK = 4096
DATA_BLOCKS = 256

pytestmark = pytest.mark.skipif(
    any(shutil.which(t) is None for t in ("mkimage", "dumpimage", "dtc", "fdtget", "fdtput",
                                         "veritysetup", "mkfs.ext4", "openssl")),
    reason="needs mkimage/dumpimage/dtc/fdtget/fdtput/veritysetup/mkfs.ext4/openssl",
)


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, text=True, **kw)


@pytest.fixture
def checker() -> str:
    tool = _find_fit_check_sign()
    if tool is None:
        pytest.skip("fit_check_sign not found on host or in the build tree")
    return tool


# ------------------------------------------------------------------ builders

def make_key(keydir: pathlib.Path, name: str) -> None:
    keydir.mkdir(exist_ok=True)
    run(["openssl", "genrsa", "-out", keydir / f"{name}.key", "2048"])
    run(["openssl", "req", "-batch", "-new", "-x509", "-key", keydir / f"{name}.key",
         "-out", keydir / f"{name}.crt", "-days", "1", "-subj", f"/CN={name}"])


def make_rootfs(deploy: pathlib.Path) -> dict:
    img = deploy / f"{IMAGE}.ext4.verity"
    size = DATA_BLOCKS * BLOCK
    run(["truncate", "-s", size, img])
    run(["mkfs.ext4", "-q", "-F", img])
    out = run(["veritysetup", "format", "--no-superblock", f"--data-block-size={BLOCK}",
               f"--hash-block-size={BLOCK}", f"--data-blocks={DATA_BLOCKS}",
               f"--hash-offset={size}", img, img]).stdout
    params = {
        "VERITY_DATA_BLOCKS": str(DATA_BLOCKS),
        "VERITY_DATA_BLOCK_SIZE": str(BLOCK),
        "VERITY_HASH_BLOCK_SIZE": str(BLOCK),
        "VERITY_HASH_ALGORITHM": "sha256",
        "VERITY_ROOT_HASH": re.search(r"Root hash:\s+(\S+)", out).group(1),
        "VERITY_SALT": re.search(r"Salt:\s+(\S+)", out).group(1),
        "VERITY_DATA_SECTORS": str(size // 512),
    }
    (deploy / f"{IMAGE}.ext4.verity-params").write_text(
        "".join(f"{k}={v}\n" for k, v in params.items()))
    return params


def bootargs(slot: str, params: dict, device: str = None, table: str = None,
             extra: str = "console=ttyAMA10,115200") -> str:
    device = device or DEVICES[slot]
    table = table or slot_fits.expected_table(params, device)
    return (f'root=/dev/dm-0 rootfstype=ext4 ro rootwait rauc.slot={slot} '
            f'dm-mod.waitfor={device} dm-mod.create="{table}" {extra}').strip()


def make_fit(work: pathlib.Path, out: pathlib.Path, args: str, keydir: pathlib.Path,
             key: str, anchor: pathlib.Path = None, two_configs: bool = False) -> None:
    (work / "chosen.dts").write_text('/dts-v1/;\n/ { compatible = "test"; chosen { }; };\n')
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", work / "slot.dtb", work / "chosen.dts"])
    run(["fdtput", "-t", "s", work / "slot.dtb", "/chosen", "bootargs", args])
    (work / "kernel.bin").write_bytes(b"\x00KERNEL" * 512)
    sig = (f'signature-1 {{ algo = "sha256,rsa2048"; key-name-hint = "{key}"; '
           f'sign-images = "kernel", "fdt"; }};')
    confs = f'conf-1 {{ kernel = "kernel-1"; fdt = "fdt-1"; {sig} }};'
    if two_configs:
        confs += f' conf-2 {{ kernel = "kernel-1"; fdt = "fdt-1"; {sig} }};'
    (work / "fit.its").write_text(f"""/dts-v1/;
/ {{
    description = "slot fit";
    #address-cells = <1>;
    images {{
        kernel-1 {{ data = /incbin/("kernel.bin"); type = "kernel"; arch = "arm64";
            os = "linux"; compression = "none"; load = <0x80000>; entry = <0x80000>;
            hash-1 {{ algo = "sha256"; }}; }};
        fdt-1 {{ data = /incbin/("slot.dtb"); type = "flat_dt"; arch = "arm64";
            compression = "none"; hash-1 {{ algo = "sha256"; }}; }};
    }};
    configurations {{ default = "conf-1"; {confs} }};
}};
""")
    cmd = ["mkimage", "-f", "fit.its", "-k", keydir, "-r"]
    if anchor:
        cmd += ["-K", anchor]
    run(cmd + [out], cwd=work)


def make_anchor(work: pathlib.Path, keydir: pathlib.Path, keys: list[str]) -> pathlib.Path:
    """A DTB trusting key-<name> for each name (required=conf), as U-Boot sees it."""
    (work / "anchor.dts").write_text('/dts-v1/;\n/ { compatible = "test"; };\n')
    anchor = work / f"anchor-{'-'.join(keys)}.dtb"
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", anchor, work / "anchor.dts"])
    for k in keys:
        scratch = work / f"keyload-{k}"
        scratch.mkdir(exist_ok=True)
        make_fit(scratch, scratch / "throwaway.fit", "x", keydir, k, anchor=anchor)
    if len(keys) > 1:
        run(["fdtput", "-t", "s", anchor, "/signature", "required-mode", "any"])
    return anchor


def make_archive(path: pathlib.Path, anchor: pathlib.Path) -> pathlib.Path:
    with tarfile.open(path, "w:gz") as tf:
        tf.add(anchor, arcname="./bcm2712-rpi-5-b.dtb")
    return path


@pytest.fixture
def bench(tmp_path):
    """deploy/ with a good file-signed pair, keys dev + prof, and helpers."""
    keydir = tmp_path / "keys"
    make_key(keydir, "dev")
    make_key(keydir, "prof")
    deploy = tmp_path / "deploy"
    deploy.mkdir()
    params = make_rootfs(deploy)

    def fit(slot: str, args: str = None, key: str = "dev", two_configs: bool = False,
            name: str = None) -> pathlib.Path:
        work = tmp_path / f"build-{slot}-{name or 'x'}"
        work.mkdir(exist_ok=True)
        out = deploy / (name or f"{IMAGE}.fitImage-{slot.lower()}")
        make_fit(work, out, args or bootargs(slot, params), keydir, key, two_configs=two_configs)
        return out

    fit("A")
    fit("B")
    anchors = tmp_path / "anchors"
    anchors.mkdir()
    return {"tmp": tmp_path, "keydir": keydir, "deploy": deploy, "params": params,
            "fit": fit, "anchors": anchors}


def slots(bench) -> slot_fits.Slots:
    return slot_fits.Slots(bench["deploy"], IMAGE, devices=dict(DEVICES))


def do_check(bench, checker, anchor_keys=("dev",), trust_keys=None):
    anchor = make_anchor(bench["anchors"], bench["keydir"], list(anchor_keys))
    archive = make_archive(bench["tmp"] / "bootfiles.tar.gz", anchor)
    work = bench["tmp"] / "extract"
    work.mkdir(exist_ok=True)
    got = slot_fits.anchor_from_archive(archive, "bcm2712-rpi-5-b.dtb", work)
    return slot_fits.check(slots(bench), got, list(trust_keys or anchor_keys),
                           "sha256,rsa2048", 2048, checker, slot_fits.DEFAULT_GATE)


# ------------------------------------------------------------------- checks

def test_good_pair_passes(bench, checker):
    assert do_check(bench, checker) == []


def test_wrong_table_device_despite_correct_waitfor(bench, checker):
    p = bench["params"]
    bench["fit"]("A", bootargs("A", p, table=slot_fits.expected_table(p, DEVICES["B"])))
    errors = do_check(bench, checker)
    assert any("slot A: dm_mod.create=" in e for e in errors), errors
    assert not any("dm_mod.waitfor" in e for e in errors), errors


@pytest.mark.parametrize("field,value", [
    ("VERITY_DATA_SECTORS", "1024"),       # mapped sector count
    ("VERITY_DATA_BLOCKS", "128"),         # data blocks + hash start
    ("VERITY_HASH_BLOCK_SIZE", "1024"),    # block size
])
def test_wrong_geometry(bench, checker, field, value):
    bad = dict(bench["params"], **{field: value})
    bench["fit"]("B", bootargs("B", bench["params"],
                               table=slot_fits.expected_table(bad, DEVICES["B"])))
    errors = do_check(bench, checker)
    assert any("slot B: dm_mod.create=" in e for e in errors), errors


def test_duplicate_and_conflicting_arguments(bench, checker):
    p = bench["params"]
    bench["fit"]("A", bootargs("A", p, extra="rauc.slot=B rw dm=x"))
    errors = do_check(bench, checker)
    assert any("rauc.slot= appears 2 times" in e for e in errors), errors
    assert any("'rw'" in e for e in errors), errors
    assert any("'dm'" in e for e in errors), errors


def test_slots_swapped(bench, checker):
    a, b = (bench["deploy"] / f"{IMAGE}.fitImage-{s}" for s in "ab")
    tmp = a.with_suffix(".tmp")
    a.rename(tmp); b.rename(a); tmp.rename(b)
    errors = do_check(bench, checker)
    assert any("slot A: rauc.slot='B'" in e for e in errors), errors


def test_stale_rootfs_fails_even_when_strings_agree(bench, checker):
    img = bench["deploy"] / f"{IMAGE}.ext4.verity"
    with open(img, "r+b") as f:
        f.seek(5 * BLOCK + 17)
        b = f.read(1)
        f.seek(5 * BLOCK + 17)
        f.write(bytes([b[0] ^ 0xFF]))
    errors = do_check(bench, checker)
    assert any("does not verify against its dm-verity root hash" in e for e in errors), errors


def test_stale_archive_anchor(bench, checker):
    # The archive ships an anchor trusting only "prof"; the FITs are dev-signed.
    errors = do_check(bench, checker, anchor_keys=("prof",))
    assert any("does not verify against" in e for e in errors), errors


def test_anchor_key_set_must_match_exactly(bench, checker):
    errors = do_check(bench, checker, anchor_keys=("dev", "prof"), trust_keys=("prof",))
    assert any("key-dev is trusted but not an enabled trust root" in e for e in errors), errors


def test_multi_config_fit_rejected(bench, checker):
    bench["fit"]("A", two_configs=True)
    errors = do_check(bench, checker)
    assert any("2 configurations, expected exactly 1" in e for e in errors), errors


def test_selection_requires_both_files(bench):
    (bench["deploy"] / f"{IMAGE}.fitImage-b").unlink()
    with pytest.raises(slot_fits.SlotFitError, match="missing slot artifact"):
        slots(bench)


# -------------------------------------------------------------------- sign

def prof_signer(bench, calls: list, fail_on: str = None, mutate: bool = False):
    """sign_one stand-in: re-sign in place with the "prof" file key."""
    def sign_one(fit: pathlib.Path) -> dict:
        calls.append(fit.name)
        if fail_on and fit.name.endswith(fail_on):
            raise RuntimeError("simulated HSM failure")
        if mutate:
            run(["fdtput", "-t", "s", fit, "/", "description", "mutated"])
            work = bench["tmp"] / "mutate"
            work.mkdir(exist_ok=True)
            make_fit(work, fit, bootargs(fit.name[-1].upper(), bench["params"],
                                         extra="console=tty1"), bench["keydir"], "prof")
            return {}
        for conf in (slot_fits._fdtget(fit, "/configurations", list_nodes=True) or "").split():
            run(["fdtput", "-t", "s", fit, f"/configurations/{conf}/signature-1",
                 "key-name-hint", "prof"])
        run(["mkimage", "-F", "-k", bench["keydir"], "-r", fit])
        return {}
    return sign_one


def do_sign(bench, checker, sign_one, anchor_keys=("prof",), force=False):
    anchor = make_anchor(bench["anchors"], bench["keydir"], list(anchor_keys))
    return slot_fits.sign(slots(bench), anchor, list(anchor_keys), "sha256,rsa2048", 2048,
                          key_name="prof", sign_one=sign_one, checker=checker,
                          gate_path=slot_fits.DEFAULT_GATE, force=force,
                          manifest=bench["deploy"] / f"{IMAGE}.slot-fits.signed")


def bootargs_of(bench, slot):
    fit = bench["deploy"] / f"{IMAGE}.fitImage-{slot.lower()}"
    work = bench["tmp"] / "probe"
    work.mkdir(exist_ok=True)
    return slot_fits.fit_bootargs(fit, work)[0]


def test_sign_pair_then_skip_on_rerun(bench, checker):
    before = {s: bootargs_of(bench, s) for s in "AB"}
    calls = []
    summary = do_sign(bench, checker, prof_signer(bench, calls))
    assert calls == [f"{IMAGE}.fitImage-a", f"{IMAGE}.fitImage-b"]
    assert {s: v["result"] for s, v in summary["slots"].items()} == {"A": "signed", "B": "signed"}
    assert {s: bootargs_of(bench, s) for s in "AB"} == before
    assert (bench["deploy"] / f"{IMAGE}.slot-fits.signed").is_file()
    assert do_check(bench, checker, anchor_keys=("prof",)) == []
    calls.clear()
    summary = do_sign(bench, checker, prof_signer(bench, calls))
    assert calls == []
    assert all(v["result"].startswith("skipped") for v in summary["slots"].values())
    do_sign(bench, checker, prof_signer(bench, calls), force=True)
    assert len(calls) == 2


def test_skip_needs_verification_not_just_the_hint(bench, checker):
    # Dev-signed FITs whose key-name-hint already says "prof", against an anchor
    # that trusts both keys: the hint matches and the multi-key anchor would
    # verify them, but the profile-only anchor does not, so they must be signed.
    for s in "ab":
        fit = bench["deploy"] / f"{IMAGE}.fitImage-{s}"
        run(["fdtput", "-t", "s", fit, "/configurations/conf-1/signature-1",
             "key-name-hint", "prof"])
    calls = []
    do_sign(bench, checker, prof_signer(bench, calls), anchor_keys=("dev", "prof"))
    assert len(calls) == 2


def test_failure_on_second_fit_restores_both(bench, checker):
    fits = [bench["deploy"] / f"{IMAGE}.fitImage-{s}" for s in "ab"]
    original = [f.read_bytes() for f in fits]
    calls = []
    with pytest.raises(RuntimeError, match="simulated HSM failure"):
        do_sign(bench, checker, prof_signer(bench, calls, fail_on="fitImage-b"))
    assert calls == [f"{IMAGE}.fitImage-a", f"{IMAGE}.fitImage-b"]
    assert [f.read_bytes() for f in fits] == original


def test_command_line_change_by_signer_is_refused(bench, checker):
    fits = [bench["deploy"] / f"{IMAGE}.fitImage-{s}" for s in "ab"]
    original = [f.read_bytes() for f in fits]
    with pytest.raises(slot_fits.SlotFitError, match="command line changed by signing"):
        do_sign(bench, checker, prof_signer(bench, [], mutate=True))
    assert [f.read_bytes() for f in fits] == original


def test_sign_refuses_a_bad_layout_before_signing(bench, checker):
    bench["fit"]("A", bootargs("A", bench["params"], device=DEVICES["B"]))
    calls = []
    with pytest.raises(slot_fits.SlotFitError, match="refusing to sign"):
        do_sign(bench, checker, prof_signer(bench, calls))
    assert calls == []


# ------------------------------------------------------------------ SoftHSM

def test_sign_slot_fits_cli_softhsm(bench, checker, softhsm_dev_key, fixture_dtb_with_pubkey):
    archive = make_archive(bench["tmp"] / "bootfiles.tar.gz", fixture_dtb_with_pubkey)
    before = {s: bootargs_of(bench, s) for s in "AB"}
    r = run_sign_fit(
        "sign-slot-fits",
        "--profile", "softhsm-test",
        "--profile-config", str(softhsm_dev_key["profile_config"]),
        "--image", IMAGE, "--deploy-dir", str(bench["deploy"]),
        "--archive", str(archive), "--keys", softhsm_dev_key["key_label"],
        "--checker", checker,
        env=softhsm_dev_key["env"], check=False,
    )
    assert r.returncode == 0, f"stdout: {r.stdout}\nstderr: {r.stderr}"
    assert {s: bootargs_of(bench, s) for s in "AB"} == before
    assert (bench["deploy"] / f"{IMAGE}.slot-fits.signed").is_file()
    r = subprocess.run(
        [sys.executable, str(slot_fits.SCRIPT_DIR / "slot_fits.py"), "check",
         "--image", IMAGE, "--deploy-dir", str(bench["deploy"]),
         "--archive", str(archive), "--keys", softhsm_dev_key["key_label"],
         "--checker", checker],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


# ------------------------------------------------------------ kernel args

def test_kernel_args_matches_next_arg():
    args = slot_fits.kernel_args('a=1  "b=two words" c="x y" \'d e\' flag -- init=z')
    assert args == [("a", "1"), ("b", "two words"), ("c", "x y"), ("'d", None),
                    ("e'", None), ("flag", None), ("--", None), ("init", "z")]


def test_underscore_spelling_override_is_refused(bench, checker):
    # The kernel reads dm_mod.create as dm-mod.create: a second table.
    p = bench["params"]
    bench["fit"]("A", bootargs("A", p, extra='dm_mod.create="vroot,,,rw,0 2048 linear /dev/mmcblk0p3 0"'))
    errors = do_check(bench, checker)
    assert any("dm_mod.create= appears 2 times" in e for e in errors), errors


def test_required_arguments_after_double_dash_are_refused(bench, checker):
    p = bench["params"]
    table = slot_fits.expected_table(p, DEVICES["A"])
    args = (f'console=ttyAMA10,115200 -- root=/dev/dm-0 rootfstype=ext4 ro rauc.slot=A '
            f'dm-mod.waitfor={DEVICES["A"]} dm-mod.create="{table}"')
    bench["fit"]("A", args)
    errors = do_check(bench, checker)
    assert any("'--' in the command line" in e for e in errors), errors


def test_single_quoted_table_is_refused(bench, checker):
    p = bench["params"]
    good = bootargs("A", p)
    bench["fit"]("A", good.replace('dm-mod.create="', "dm-mod.create='").replace(
        'restart_on_corruption"', "restart_on_corruption'"))
    errors = do_check(bench, checker)
    assert any("single quote" in e for e in errors), errors


@pytest.mark.parametrize("field,value,match", [
    ("VERITY_DATA_SECTORS", "1", "maps 512 bytes"),
    ("VERITY_DATA_SECTORS", "x", "not a positive integer"),
    ("VERITY_DATA_BLOCK_SIZE", "3000", "power of two"),
    ("VERITY_ROOT_HASH", "abcd", "hex digest"),
])
def test_invalid_geometry_even_when_fit_and_params_agree(bench, field, value, match):
    # Rewrite params AND rebuild both FITs from them, so the strings agree.
    bad = dict(bench["params"], **{field: value})
    (bench["deploy"] / f"{IMAGE}.ext4.verity-params").write_text(
        "".join(f"{k}={v}\n" for k, v in bad.items()))
    if value.isalnum():
        for s in "AB":
            bench["fit"](s, bootargs(s, bad))
    with pytest.raises(slot_fits.SlotFitError, match=match):
        slots(bench)


def test_partial_backup_failure_leaves_both_fits_untouched(bench, checker, monkeypatch):
    fits = [bench["deploy"] / f"{IMAGE}.fitImage-{s}" for s in "ab"]
    original = [f.read_bytes() for f in fits]
    real_copy2, calls = shutil.copy2, []

    def flaky_copy2(src, dst, *a, **kw):
        calls.append(pathlib.Path(src).name)
        if len(calls) == 2:              # the backup of B
            pathlib.Path(dst).write_bytes(b"half a backup")
            raise OSError("disk full")
        return real_copy2(src, dst, *a, **kw)

    monkeypatch.setattr(slot_fits.shutil, "copy2", flaky_copy2)
    signed = []
    with pytest.raises(OSError, match="disk full"):
        do_sign(bench, checker, prof_signer(bench, signed))
    assert signed == []
    assert [f.read_bytes() for f in fits] == original
