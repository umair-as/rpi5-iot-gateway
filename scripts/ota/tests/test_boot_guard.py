"""Tests for the /boot guards in iotgw-boot-guard:
- iotgw-fit-anchor.sh: would U-Boot, booting with a given board DTB (the FIT
  trust anchor), accept a slot FIT?
- iotgw-rauc-preinstall: the RAUC system pre-install handler, which refuses a
  bundle before any slot is written.

Fixtures are generated per run: throwaway RSA keys, a FIT signed with mkimage
and anchor DTBs in the trust states that matter (one key, two keys with
required-mode any, two keys without it). Skipped when the U-Boot/dtc host tools
are missing.
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
FILES = REPO / "meta-iot-gateway/recipes-ota/iotgw-boot-guard/files"
LIB = FILES / "iotgw-fit-anchor.sh"
HANDLER = FILES / "iotgw-rauc-preinstall"

TOOLS = ("mkimage", "dtc", "fdtget", "fdtput", "fdt_add_pubkey", "openssl")
pytestmark = pytest.mark.skipif(
    any(shutil.which(t) is None for t in TOOLS),
    reason="needs %s on the host" % ", ".join(TOOLS))

BASE_DTS = "/dts-v1/;\n/ { model = \"test\"; compatible = \"test\"; };\n"


def sh(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw)


def its(signers):
    sigs = "".join(
        f"""                signature-{i} {{
                    algo = "sha256,rsa2048";
                    key-name-hint = "{name}";
                    sign-images = "kernel", "fdt";
                }};
""" for i, name in enumerate(signers, 1))
    return f"""/dts-v1/;
/ {{
    description = "test";
    #address-cells = <1>;
    images {{
        kernel-1 {{
            data = /incbin/("kernel.bin");
            type = "kernel"; arch = "arm64"; os = "linux"; compression = "none";
            load = <0x80000>; entry = <0x80000>;
            hash-1 {{ algo = "sha256"; }};
        }};
        fdt-1 {{
            data = /incbin/("base.dtb");
            type = "flat_dt"; arch = "arm64"; compression = "none";
            hash-1 {{ algo = "sha256"; }};
        }};
    }};
    configurations {{
        default = "conf-1";
        conf-1 {{
            kernel = "kernel-1";
            fdt = "fdt-1";
{sigs}        }};
    }};
}};
"""


@pytest.fixture(scope="module")
def fx(tmp_path_factory):
    d = tmp_path_factory.mktemp("bootguard")
    keys = d / "keys"
    keys.mkdir()
    for name in ("kdev", "kyk", "kother"):
        sh("openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
           "-out", str(keys / f"{name}.key"))
        sh("openssl", "req", "-batch", "-new", "-x509", "-key", str(keys / f"{name}.key"),
           "-out", str(keys / f"{name}.crt"), "-subj", f"/CN={name}", "-days", "2")
    (d / "kernel.bin").write_bytes(os.urandom(4096))
    (d / "base.dts").write_text(BASE_DTS)
    sh("dtc", "-I", "dts", "-O", "dtb", "-o", str(d / "base.dtb"), str(d / "base.dts"))

    def fit(name, signers):
        (d / f"{name}.its").write_text(its(signers))
        sh("mkimage", "-f", f"{name}.its", "-k", str(keys), f"{name}.itb", cwd=d)
        return d / f"{name}.itb"

    def anchor(name, required, mode=None, extra=()):
        out = d / f"{name}.dtb"
        shutil.copy(d / "base.dtb", out)
        for k in required:
            sh("fdt_add_pubkey", "-a", "sha256,rsa2048", "-k", str(keys), "-n", k, "-r", "conf", str(out))
        for k in extra:  # present but not required
            sh("fdt_add_pubkey", "-a", "sha256,rsa2048", "-k", str(keys), "-n", k, str(out))
        if mode:
            sh("fdtput", "-t", "s", str(out), "/signature", "required-mode", mode)
        return out

    return {
        "dir": d,
        "fit_dev": fit("fit_dev", ["kdev"]),
        "fit_both": fit("fit_both", ["kdev", "kyk"]),
        "fit_other": fit("fit_other", ["kother"]),
        "a_dev": anchor("a_dev", ["kdev"]),
        "a_dual_any": anchor("a_dual_any", ["kdev", "kyk"], mode="any"),
        "a_dual_all": anchor("a_dual_all", ["kdev", "kyk"]),
        "a_yk": anchor("a_yk", ["kyk"]),
        "a_yk_knows_dev": anchor("a_yk_knows_dev", ["kyk"], extra=["kdev"]),
        "a_none": anchor("a_none", [], extra=["kdev"]),
    }


def check(fit, cur, cand):
    r = subprocess.run(["bash", "-c", f'. "{LIB}"; fit_anchor_check "$1" "$2" "$3"', "_",
                        str(fit), str(cur), str(cand)], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


@pytest.mark.parametrize("fit,cur,cand,ok", [
    # Same anchor: the FIT boots as it does today.
    ("fit_dev", "a_dev", "a_dev", True),
    # Rotation window: a second key added with required-mode any keeps the old FIT bootable.
    ("fit_dev", "a_dev", "a_dual_any", True),
    # Added without required-mode (U-Boot default "all"): the old FIT lacks the new signature.
    ("fit_dev", "a_dev", "a_dual_all", False),
    # A FIT signed by both keys satisfies "all".
    ("fit_both", "a_dual_any", "a_dual_all", True),
    # The release cutover: the file key retired while a slot still has a file-key FIT.
    ("fit_dev", "a_dual_any", "a_yk", False),
    # The old key still in the DTB but no longer required: U-Boot ignores it.
    ("fit_dev", "a_dual_any", "a_yk_knows_dev", False),
    # No required key at all would let U-Boot boot unsigned FITs.
    ("fit_dev", "a_dev", "a_none", False),
    # Signer unknown to the current anchor: its key cannot be identified.
    ("fit_other", "a_dev", "a_dual_any", False),
])
def test_anchor_check(fx, fit, cur, cand, ok):
    rc, out = check(fx[fit], fx[cur], fx[cand])
    assert (rc == 0) == ok, out


def test_anchor_check_matches_u_boot(fx):
    """Cross-check against U-Boot's own verifier where it applies."""
    if shutil.which("fit_check_sign") is None:
        pytest.skip("fit_check_sign not installed")
    for fit, anchor, ok in (("fit_dev", "a_dev", True), ("fit_dev", "a_yk", False),
                            ("fit_both", "a_dual_all", True), ("fit_dev", "a_dual_all", False)):
        r = subprocess.run(["fit_check_sign", "-f", str(fx[fit]), "-k", str(fx[anchor])],
                           capture_output=True, text=True)
        assert (r.returncode == 0) == ok, (fit, anchor, r.stdout + r.stderr)
        assert (check(fx[fit], fx[anchor], fx[anchor])[0] == 0) == ok, (fit, anchor)


def bundle(tmp, fx, *, abi="2", hooks="pre-install;post-install", hook_file=True,
           bootfiles=True, fits=("a", "b"), extra_fit=None, fit="fit_dev"):
    b = tmp / "bundle"
    b.mkdir()
    lines = ["[update]", "compatible=iot-gateway-raspberrypi5", "version=0.7.0", ""]
    if hook_file is not None:
        lines += ["[hooks]", "filename=bundle-hooks-fit.sh", ""]
    lines += ["[image.rootfs]", "filename=rootfs.ext4.verity"]
    if hooks is not None:
        lines.append(f"hooks={hooks}")
    lines.append("")
    if abi is not None:
        lines += ["[meta.iotgw]", f"bundle-abi={abi}", ""]
    (b / "manifest.raucm").write_text("\n".join(lines))
    if hook_file:
        (b / "bundle-hooks-fit.sh").write_text("#!/bin/sh\n")
    if bootfiles:
        (b / "bootfiles-fit.tar.gz").write_bytes(b"x")
    for s in fits:
        shutil.copy(fx[fit], b / f"img.fitImage-{s}")
    if extra_fit:
        shutil.copy(fx[fit], b / f"img2.fitImage-{extra_fit}")
    return b


def run_handler(tmp, fx, b, *, anchor="a_dual_any", slot_type="raw", slot_class="rootfs",
                degraded=False):
    boot = tmp / "boot"
    boot.mkdir()
    shutil.copy(fx[anchor], boot / "bcm2712-rpi-5-b.dtb")
    marker = tmp / "degraded"
    if degraded:
        marker.write_text("data-missing")
    env = dict(os.environ,
               RAUC_BUNDLE_MOUNT_POINT=str(b), RAUC_TARGET_SLOTS="2",
               RAUC_SLOT_NAME_2="rootfs.1", RAUC_SLOT_CLASS_2=slot_class,
               RAUC_SLOT_TYPE_2=slot_type,
               IOTGW_BOOT_MP=str(boot), IOTGW_DEGRADED_MARKER=str(marker),
               IOTGW_FIT_ANCHOR_LIB=str(LIB))
    r = subprocess.run(["bash", str(HANDLER)], env=env, capture_output=True, text=True)
    return r.returncode, r.stderr


def test_handler_accepts_current_bundle(fx, tmp_path):
    rc, err = run_handler(tmp_path, fx, bundle(tmp_path, fx))
    assert rc == 0, err
    assert "bundle accepted" in err


@pytest.mark.parametrize("kw,expect", [
    ({"abi": None}, "bundle ABI 'none'"),
    ({"abi": "1"}, "bundle ABI '1'"),
    ({"hooks": None}, "pre-install hook"),
    ({"hooks": "post-install"}, "pre-install hook"),
    ({"hooks": "pre-install"}, "post-install hook"),
    ({"hook_file": None}, "hook script"),
    ({"hook_file": False}, "hook script"),
    ({"bootfiles": False}, "bootfiles-fit.tar.gz"),
    ({"fits": ("a",)}, "0 *.fitImage-b"),
    ({"fits": ()}, "0 *.fitImage-a"),
    ({"extra_fit": "a"}, "2 *.fitImage-a"),
    ({"fit": "fit_other"}, "would not boot with the current trust anchor"),
])
def test_handler_refuses_bundle(fx, tmp_path, kw, expect):
    rc, err = run_handler(tmp_path, fx, bundle(tmp_path, fx, **kw))
    assert rc != 0
    assert expect in err, err


@pytest.mark.parametrize("kw,expect", [
    ({"anchor": "a_yk"}, "would not boot with the current trust anchor"),
    ({"anchor": "a_dual_all"}, "would not boot with the current trust anchor"),
    ({"slot_type": "ext4"}, "not a raw dm-verity slot"),
    ({"slot_class": "bootloader"}, "not rootfs"),
    ({"degraded": True}, "degraded"),
])
def test_handler_refuses_system_state(fx, tmp_path, kw, expect):
    rc, err = run_handler(tmp_path, fx, bundle(tmp_path, fx), **kw)
    assert rc != 0
    assert expect in err, err


UPDATER = FILES / "iotgw-rpi-bootfiles-update.sh"
ARTIFACTS = ("kernel_2712.img", "bcm2712-rpi-5-b.dtb", "config.txt")
needs_userns = pytest.mark.skipif(
    subprocess.run(["unshare", "-r", "true"], capture_output=True).returncode != 0,
    reason="needs unprivileged user namespaces (unshare -r)")


def sha(p):
    import hashlib
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def updater_env(tmp, fx, *, cand_anchor, fits=("a", "b"), rw=True, config="arm_64bit=1\n# new\n"):
    boot, stage, shim = tmp / "boot", tmp / "stage", tmp / "shim"
    for d in (boot, stage, shim):
        d.mkdir()
    shutil.copy(fx["a_dev"], boot / "bcm2712-rpi-5-b.dtb")
    # A device updated by older bundles: Linux in kernel_2712.img, U-Boot via kernel=.
    (boot / "config.txt").write_text("kernel=u-boot.bin\n")
    (boot / "u-boot.bin").write_bytes(b"old-u-boot")
    (boot / "kernel_2712.img").write_bytes(b"linux-image")
    for s in fits:
        shutil.copy(fx["fit_dev"], boot / f"fitImage-{s}")
    shutil.copy(fx[cand_anchor], stage / "bcm2712-rpi-5-b.dtb")
    (stage / "config.txt").write_text(config)
    (stage / "kernel_2712.img").write_bytes(b"new-u-boot")
    rows = ["artifact\tsha256\tsize\tboot_target"]
    for a in ARTIFACTS:
        rows.append(f"{a}\t{sha(stage / a)}\t{(stage / a).stat().st_size}\t{a}")
    (stage / "manifest.tsv").write_text("\n".join(rows) + "\n")
    # The tool insists on a mounted read-write FAT /boot; report one.
    opts = "rw,noatime" if rw else "ro,noatime"
    (shim / "findmnt").write_text(f"#!/bin/sh\necho 'vfat {opts}'\n")
    (shim / "findmnt").chmod(0o755)
    env = dict(os.environ, PATH=f"{shim}:{os.environ['PATH']}", BOOT_MP=str(boot),
               ROOT_DIR=str(stage), BACKUP_DIR=str(tmp / "backup"),
               IOTGW_FIT_ANCHOR_LIB=str(LIB), IOTGW_DROP_CACHES=str(tmp / "drop_caches"))
    return boot, stage, env


def updater(env, *args):
    r = subprocess.run(["unshare", "-r", "bash", str(UPDATER), *args], env=env,
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def boot_state(boot):
    return {p.name: sha(p) for p in sorted(boot.iterdir()) if p.is_file()}


@needs_userns
def test_updater_apply_and_restore(fx, tmp_path):
    boot, stage, env = updater_env(tmp_path, fx, cand_anchor="a_dual_any")
    before = boot_state(boot)
    rc, out = updater(env, "--dry-run")
    assert rc == 0 and "3 file(s) would be written" in out, out
    assert boot_state(boot) == before
    rc, out = updater(env, "--yes")
    assert rc == 0, out
    for a in ARTIFACTS:
        assert sha(boot / a) == sha(stage / a), a
    assert not list(boot.glob(".*.new")), "temporary file left behind"
    rc, out = updater(env, "--yes")
    assert rc == 0 and "already current" in out, out
    runs = sorted((tmp_path / "backup").iterdir())
    assert len(runs) == 1
    # Restoring brings back the old anchor; both slot FITs are still trusted by it.
    rc, out = updater(env, "--restore", runs[0].name, "--yes")
    assert rc == 0, out
    assert boot_state(boot) == before


@needs_userns
@pytest.mark.parametrize("cand,expect", [
    ("a_yk", "slot a would not boot"),
    ("a_dual_all", "slot a would not boot"),
    ("a_none", "no required"),
])
def test_updater_refuses_anchor_before_any_write(fx, tmp_path, cand, expect):
    boot, _, env = updater_env(tmp_path, fx, cand_anchor=cand)
    before = boot_state(boot)
    rc, out = updater(env, "--yes")
    assert rc != 0 and expect in out, out
    assert boot_state(boot) == before
    assert not (tmp_path / "backup").exists(), "backed up although nothing may be written"


@needs_userns
def test_updater_refuses_read_only_boot(fx, tmp_path):
    boot, _, env = updater_env(tmp_path, fx, cand_anchor="a_dev", rw=False)
    before = boot_state(boot)
    rc, out = updater(env, "--yes")
    assert rc != 0 and "not mounted read-write" in out, out
    assert boot_state(boot) == before


@needs_userns
def test_updater_refuses_restore_of_incompatible_anchor(fx, tmp_path):
    """A restore runs through the same anchor guard as an update."""
    boot, stage, env = updater_env(tmp_path, fx, cand_anchor="a_dual_any")
    assert updater(env, "--yes")[0] == 0
    run = sorted((tmp_path / "backup").iterdir())[0]
    # Simulate a backup whose anchor no longer trusts the installed slot FITs.
    shutil.copy(fx["a_yk"], run / "bcm2712-rpi-5-b.dtb")
    meta = run / "bcm2712-rpi-5-b.dtb.meta"
    meta.write_text(meta.read_text().replace(
        meta.read_text().split("sha256\t")[1].split("\n")[0], sha(run / "bcm2712-rpi-5-b.dtb")))
    before = boot_state(boot)
    rc, out = updater(env, "--restore", run.name, "--yes")
    assert rc != 0 and "would not boot" in out, out
    assert boot_state(boot) == before


@needs_userns
@pytest.mark.parametrize("config,ok", [
    ("arm_64bit=1\n", True),
    ("kernel=kernel_2712.img\n", True),
    ("kernel=u-boot.bin\n", True),
    ("kernel=Image\n", False),
    ("kernel=kernel_2712.img\nkernel=Image  # later line wins\n", False),
])
def test_updater_config_must_boot_u_boot(fx, tmp_path, config, ok):
    boot, _, env = updater_env(tmp_path, fx, cand_anchor="a_dev", config=config)
    before = boot_state(boot)
    rc, out = updater(env, "--yes")
    assert (rc == 0) == ok, out
    if not ok:
        assert "only U-Boot" in out, out
        assert boot_state(boot) == before


@needs_userns
def test_updater_writes_u_boot_first_config_last(fx, tmp_path):
    boot, _, env = updater_env(tmp_path, fx, cand_anchor="a_dual_any")
    rc, out = updater(env, "--yes")
    assert rc == 0, out
    order = [l.split()[1] for l in out.splitlines() if l.endswith("written and verified")]
    assert order == ["kernel_2712.img", "bcm2712-rpi-5-b.dtb", "config.txt"], order
