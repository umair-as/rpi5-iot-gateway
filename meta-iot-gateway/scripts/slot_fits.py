#!/usr/bin/env python3
"""Per-slot dm-verity FIT checks and detached re-signing.

Runtime dm-verity ships two FITs per image, <image>.fitImage-a and -b. Each
one's device tree carries the kernel command line, and with it the slot's
dm-verity table. The build signs them with the file key; a release bundle
needs them re-signed by the operator's HSM key (YubiKey, or SoftHSM for dev).

This module holds the checks that make that safe, and the sign/rollback
loop. It lives in the layer next to iotgw-fit-gate.py so the bundle recipe can
run `check` on the files it stages (found via BBPATH, stdlib only), and
scripts/fit-signing/sign_fit.py's `sign-slot-fits` subcommand imports it to
drive `sign`, handing in the function that signs one FIT.

check   Both FITs and the rootfs they boot belong together:
        - single-configuration FITs, kernel + fdt only, every config signed
          over both (iotgw-fit-gate.py coverage) and verifying against the
          trust anchor taken from the bootfiles archive the bundle ships;
        - each command line holds exactly the slot's identity and a
          dm-mod.create table equal, byte for byte, to the one the image
          recipe generates from <image>.ext4.verity-params for that slot's
          device (devices, block sizes, sector count, hash start, salt);
        - veritysetup verifies the rootfs file itself against that table, so a
          stale or substituted rootfs fails even when every string agrees.
sign    The above, then per FIT: skip only if it already carries the signing
        profile's key AND verifies against an anchor holding only that key;
        otherwise sign it and confirm the command line came through unchanged.
        A failure on either FIT restores both.

Exit 0 when every check passes, 1 with one line per failure otherwise.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from typing import Callable, Optional

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_GATE = SCRIPT_DIR / "iotgw-fit-gate.py"
DEFAULT_ANCHOR_MEMBER = "bcm2712-rpi-5-b.dtb"
DEFAULT_SLOT_DEVICES = {"A": "/dev/mmcblk0p3", "B": "/dev/mmcblk0p4"}

# Mirrors iotgw-verity-image.bbclass (iotgw_verity_parse_params). Kept strict:
# these values reach a kernel command line.
PARAMS_REQUIRED = ("VERITY_DATA_BLOCKS", "VERITY_DATA_BLOCK_SIZE",
                   "VERITY_HASH_BLOCK_SIZE", "VERITY_HASH_ALGORITHM",
                   "VERITY_ROOT_HASH", "VERITY_SALT", "VERITY_DATA_SECTORS")

# Command-line arguments that decide what the kernel mounts as root. Each must
# appear exactly once; anything else that could redefine the root is refused.
# Names are compared the way the kernel does (kernel/params.c parameq: '-' and
# '_' are the same character), so they are kept here in the '_' spelling.
ROOT_ARGS = ("root", "rootfstype", "rauc.slot", "dm_mod.waitfor", "dm_mod.create")
# The arguments iotgw_verity_bootargs strips from the firmware command line
# because they would contradict the authenticated root.
REFUSED_NAMES = ("rootflags", "dm", "rw")

# Configuration properties a slot FIT may use; anything else (ramdisk,
# loadables, overlays) is not what the image recipe generates.
ALLOWED_CONF_IMAGES = {"kernel", "fdt"}


class SlotFitError(Exception):
    """Input or tooling problem that stops the run outright."""


def _run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SlotFitError(f"required tool not on PATH: {name}")
    return path


def _fdtget(dtb: pathlib.Path, node: str, prop: Optional[str] = None,
            list_nodes: bool = False) -> Optional[str]:
    cmd = [_tool("fdtget")]
    if list_nodes:
        cmd.append("-l")
    cmd += [str(dtb), node] + ([prop] if prop else [])
    r = _run(cmd)
    return r.stdout.rstrip("\n") if r.returncode == 0 else None


# ---------------------------------------------------------------- verity table

HASH_HEX_LEN = {"sha256": 64, "sha512": 128}


def parse_verity_params(text: str) -> dict[str, str]:
    params = {}
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        if not re.fullmatch(r"[A-Z0-9_]+=[A-Za-z0-9_-]*", raw):
            raise SlotFitError(f"unsafe dm-verity parameter line: {raw!r}")
        key, value = raw.split("=", 1)
        params[key] = value
    missing = sorted(k for k in PARAMS_REQUIRED if not params.get(k))
    if missing:
        raise SlotFitError("missing dm-verity parameters: " + ", ".join(missing))
    _check_geometry(params)
    return params


def _check_geometry(params: dict[str, str]) -> None:
    """A FIT and a params file that agree can still describe a wrong mapping;
    the geometry has to be consistent in itself before it reaches a table."""
    nums = {}
    for key in ("VERITY_DATA_BLOCKS", "VERITY_DATA_BLOCK_SIZE",
                "VERITY_HASH_BLOCK_SIZE", "VERITY_DATA_SECTORS"):
        if not params[key].isdigit() or int(params[key]) <= 0:
            raise SlotFitError(f"{key}={params[key]!r} is not a positive integer")
        nums[key] = int(params[key])
    for key in ("VERITY_DATA_BLOCK_SIZE", "VERITY_HASH_BLOCK_SIZE"):
        size = nums[key]
        if size < 512 or size & (size - 1):
            raise SlotFitError(f"{key}={size} is not a power of two >= 512")
    data_bytes = nums["VERITY_DATA_BLOCKS"] * nums["VERITY_DATA_BLOCK_SIZE"]
    if nums["VERITY_DATA_SECTORS"] * 512 != data_bytes:
        raise SlotFitError(
            f"VERITY_DATA_SECTORS={nums['VERITY_DATA_SECTORS']} maps "
            f"{nums['VERITY_DATA_SECTORS'] * 512} bytes, but the data is "
            f"{nums['VERITY_DATA_BLOCKS']} x {nums['VERITY_DATA_BLOCK_SIZE']} = {data_bytes} bytes")
    alg = params["VERITY_HASH_ALGORITHM"]
    if alg not in HASH_HEX_LEN:
        raise SlotFitError(f"VERITY_HASH_ALGORITHM={alg!r} is not supported")
    if not re.fullmatch(r"[0-9a-f]{%d}" % HASH_HEX_LEN[alg], params["VERITY_ROOT_HASH"]):
        raise SlotFitError(f"VERITY_ROOT_HASH is not a {alg} hex digest")
    if not re.fullmatch(r"(?:[0-9a-f]{2})+", params["VERITY_SALT"]):
        raise SlotFitError("VERITY_SALT is not hex")


def expected_table(params: dict[str, str], device: str) -> str:
    """The dm-mod.create= table iotgw-verity-image.bbclass generates."""
    return ("vroot,,,ro,0 {sectors} verity 1 {dev} {dev} {data_bs} {hash_bs} "
            "{data_blocks} {data_blocks} {algorithm} {root_hash} {salt} "
            "1 restart_on_corruption").format(
        sectors=params["VERITY_DATA_SECTORS"], dev=device,
        data_bs=params["VERITY_DATA_BLOCK_SIZE"],
        hash_bs=params["VERITY_HASH_BLOCK_SIZE"],
        data_blocks=params["VERITY_DATA_BLOCKS"],
        algorithm=params["VERITY_HASH_ALGORITHM"],
        root_hash=params["VERITY_ROOT_HASH"], salt=params["VERITY_SALT"])


def kernel_args(cmdline: str) -> list[tuple[str, Optional[str]]]:
    """(name, value) pairs as the kernel splits the command line.

    A port of lib/cmdline.c next_arg: only double quotes group, a quote may
    open the whole argument or its value, and quotes are stripped the same
    way. Single quotes are ordinary characters. A bare "--" is returned as
    its own entry; the kernel stops there and hands the rest to init."""
    args, i, n = [], 0, len(cmdline)
    while i < n:
        while i < n and cmdline[i].isspace():
            i += 1
        if i >= n:
            break
        quoted = in_quote = cmdline[i] == '"'
        start = i + 1 if quoted else i
        j, equals = start, -1
        while j < n:
            c = cmdline[j]
            if c.isspace() and not in_quote:
                break
            if equals < 0 and c == "=":
                equals = j
            if c == '"':
                in_quote = not in_quote
            j += 1
        end = j
        if quoted and end > start and cmdline[end - 1] == '"':
            end -= 1
        if equals < 0:
            name, value = cmdline[start:end], None
        else:
            name, value = cmdline[start:equals], cmdline[equals + 1:end]
            if value.startswith('"'):
                value = value[1:]
                if value.endswith('"'):
                    value = value[:-1]
        args.append((name, value))
        i = j
    return args


def _canonical(name: str) -> str:
    return name.replace("-", "_")


def check_bootargs(bootargs: str, slot: str, device: str,
                   params: dict[str, str]) -> list[str]:
    """Errors for one slot's command line; empty when it is exactly right.

    Checked as the kernel will read it (kernel_args). Forms the image recipe
    never writes, and which the kernel reads differently from how they look,
    are refused outright: single quotes, and a "--" after which arguments
    reach init instead of the kernel."""
    if "'" in bootargs:
        return [f"slot {slot}: single quote in the command line (the kernel does not treat it as quoting)"]
    args = kernel_args(bootargs)
    if ("--", None) in args:
        return [f"slot {slot}: '--' in the command line (arguments after it go to init, not the kernel)"]
    seen: dict[str, list[str]] = {k: [] for k in ROOT_ARGS}
    errors = []
    for name, value in args:
        key = _canonical(name)
        if key in seen:
            seen[key].append(value if value is not None else "")
        elif key.startswith("dm_mod.") or key in REFUSED_NAMES:
            errors.append(f"slot {slot}: refused root-defining argument {name!r}")
    ro = sum(1 for name, value in args if name == "ro" and value is None)
    if ro != 1:
        errors.append(f"slot {slot}: expected 'ro' exactly once, found {ro}")
    for key, values in seen.items():
        if len(values) != 1:
            errors.append(f"slot {slot}: {key}= appears {len(values)} times (want exactly 1)")
    if errors:
        return errors
    want = {
        "root": "/dev/dm-0",
        "rootfstype": "ext4",
        "rauc.slot": slot,
        "dm_mod.waitfor": device,
        "dm_mod.create": expected_table(params, device),
    }
    for key, value in want.items():
        if seen[key][0] != value:
            errors.append(f"slot {slot}: {key}={seen[key][0]!r}, expected {value!r}")
    return errors


def verify_rootfs(image: pathlib.Path, params: dict[str, str]) -> list[str]:
    """veritysetup over the rootfs bytes, in the format meta-oe produces."""
    if params["VERITY_DATA_BLOCK_SIZE"] != params["VERITY_HASH_BLOCK_SIZE"]:
        # The generated table puts the hash tree at block <data_blocks>, which
        # is only the byte offset of the appended tree when the sizes agree.
        return [f"{image}: data and hash block sizes differ; unsupported layout"]
    offset = int(params["VERITY_DATA_BLOCKS"]) * int(params["VERITY_DATA_BLOCK_SIZE"])
    cmd = [_tool("veritysetup"), "verify", "--no-superblock",
           f"--hash={params['VERITY_HASH_ALGORITHM']}",
           f"--salt={params['VERITY_SALT']}",
           f"--data-blocks={params['VERITY_DATA_BLOCKS']}",
           f"--data-block-size={params['VERITY_DATA_BLOCK_SIZE']}",
           f"--hash-block-size={params['VERITY_HASH_BLOCK_SIZE']}",
           f"--hash-offset={offset}",
           str(image), str(image), params["VERITY_ROOT_HASH"]]
    r = _run(cmd)
    if r.returncode != 0:
        detail = (r.stdout + r.stderr).strip().splitlines()[-1:] or ["no output"]
        return [f"{image}: does not verify against its dm-verity root hash: {detail[0]}"]
    return []


# ----------------------------------------------------------------- FIT layout

def fit_bootargs(fit: pathlib.Path, work: pathlib.Path) -> tuple[Optional[str], list[str]]:
    """Command line of the device tree the FIT boots. Requires the generated
    single-configuration layout, so there is no other configuration whose
    device tree U-Boot could be asked to use instead."""
    confs = (_fdtget(fit, "/configurations", list_nodes=True) or "").split()
    if len(confs) != 1:
        return None, [f"{fit}: {len(confs)} configurations, expected exactly 1"]
    conf = confs[0]
    node = f"/configurations/{conf}"
    errors = []
    default = _fdtget(fit, "/configurations", "default")
    if default is not None and default != conf:
        errors.append(f"{fit}: default configuration {default!r} is not {conf!r}")
    props = _run([_tool("fdtget"), "-p", str(fit), node]).stdout.split()
    image_props = {p for p in props if p in ("kernel", "fdt", "ramdisk", "loadables",
                                              "firmware", "setup", "standalone")}
    if image_props != ALLOWED_CONF_IMAGES:
        errors.append(f"{fit}: {conf} references {sorted(image_props)}, expected kernel+fdt only")
    fdt_name = _fdtget(fit, node, "fdt")
    images = (_fdtget(fit, "/images", list_nodes=True) or "").split()
    if not fdt_name or fdt_name not in images:
        return None, errors + [f"{fit}: {conf} fdt {fdt_name!r} not among /images"]
    if errors:
        return None, errors
    out = work / f"{fit.name}.fdt.dtb"
    r = _run([_tool("dumpimage"), "-T", "flat_dt", "-p", str(images.index(fdt_name)),
              "-o", str(out), str(fit)])
    if r.returncode != 0 or not out.is_file():
        return None, [f"{fit}: cannot extract fdt {fdt_name!r}: {r.stderr.strip()}"]
    bootargs = _fdtget(out, "/chosen", "bootargs")
    if bootargs is None:
        return None, [f"{fit}: fdt {fdt_name!r} has no /chosen/bootargs"]
    return bootargs, []


def key_name_hints(fit: pathlib.Path) -> list[str]:
    hints = []
    for conf in (_fdtget(fit, "/configurations", list_nodes=True) or "").split():
        node = f"/configurations/{conf}"
        for sig in (_fdtget(fit, node, list_nodes=True) or "").split():
            if sig.startswith("signature"):
                hints.append(_fdtget(fit, f"{node}/{sig}", "key-name-hint") or "")
    return hints


# --------------------------------------------------------------------- anchor

def anchor_from_archive(archive: pathlib.Path, member: str, work: pathlib.Path) -> pathlib.Path:
    """The trust anchor the bundle actually ships, not a loose deploy copy."""
    try:
        with tarfile.open(archive, "r:gz") as tf:
            names = {n.lstrip("./"): n for n in tf.getnames()}
            if member not in names:
                raise SlotFitError(f"{archive}: no {member} in the archive")
            tf.extract(names[member], work, filter="data")
    except tarfile.TarError as e:
        raise SlotFitError(f"{archive}: {e}") from e
    return work / member


def anchor_keys(anchor: pathlib.Path) -> list[str]:
    """Trust roots the anchor holds, without the key- prefix."""
    return [k[len("key-"):] for k in (_fdtget(anchor, "/signature", list_nodes=True) or "").split()
            if k.startswith("key-")]


def profile_anchor(anchor: pathlib.Path, key_name: str, out: pathlib.Path) -> pathlib.Path:
    """Copy of the anchor trusting only key-<key_name>. A FIT verifies against it
    only if that specific key signed it, whatever else the anchor trusts."""
    keys = [k for k in (_fdtget(anchor, "/signature", list_nodes=True) or "").split()
            if k.startswith("key-")]
    if f"key-{key_name}" not in keys:
        raise SlotFitError(f"{anchor}: does not trust key-{key_name} (has {keys or 'none'})")
    shutil.copyfile(anchor, out)
    for k in keys:
        if k != f"key-{key_name}":
            r = _run([_tool("fdtput"), "-r", str(out), f"/signature/{k}"])
            if r.returncode != 0:
                raise SlotFitError(f"cannot drop {k} from {out}: {r.stderr.strip()}")
    # One key left: an explicit required-mode is no longer meaningful.
    _run([_tool("fdtput"), "-d", str(out), "/signature", "required-mode"])
    return out


def gate(args: list[str], gate_path: pathlib.Path) -> list[str]:
    r = _run([sys.executable, str(gate_path)] + args)
    if r.returncode == 0:
        return []
    return [l for l in r.stderr.strip().splitlines() if l] or [f"gate failed: {args}"]


# ---------------------------------------------------------------- the checks

class Slots:
    """The selected pair and everything it is checked against."""

    def __init__(self, deploy_dir: pathlib.Path, image: str,
                 rootfs: Optional[pathlib.Path] = None,
                 params: Optional[pathlib.Path] = None,
                 fit_a: Optional[pathlib.Path] = None,
                 fit_b: Optional[pathlib.Path] = None,
                 devices: Optional[dict[str, str]] = None):
        if "/" in image or not image:
            raise SlotFitError(f"--image must be an image link name, got {image!r}")
        self.fits = {
            "A": fit_a or deploy_dir / f"{image}.fitImage-a",
            "B": fit_b or deploy_dir / f"{image}.fitImage-b",
        }
        self.rootfs = rootfs or deploy_dir / f"{image}.ext4.verity"
        self.params_path = params or deploy_dir / f"{image}.ext4.verity-params"
        self.devices = devices or dict(DEFAULT_SLOT_DEVICES)
        missing = [str(p) for p in (*self.fits.values(), self.rootfs, self.params_path)
                   if not p.is_file()]
        if missing:
            raise SlotFitError("missing slot artifact(s): " + ", ".join(missing))
        self.params = parse_verity_params(self.params_path.read_text())

    def check_layout(self, work: pathlib.Path) -> tuple[dict[str, str], list[str]]:
        """Slot identity + full table for both FITs, and the rootfs bytes."""
        errors, bootargs = [], {}
        for slot, fit in self.fits.items():
            args, errs = fit_bootargs(fit, work)
            errors += errs
            if args is not None:
                bootargs[slot] = args
                errors += check_bootargs(args, slot, self.devices[slot], self.params)
        errors += verify_rootfs(self.rootfs, self.params)
        return bootargs, errors

    def check_trust(self, anchor: pathlib.Path, keys: list[str], algo: str, bits: int,
                    checker: str, gate_path: pathlib.Path) -> list[str]:
        errors = gate(["anchor", "--dtb", str(anchor), "--keys", *keys,
                       "--algo", algo, "--bits", str(bits)], gate_path)
        for fit in self.fits.values():
            errors += gate(["fit", "--dtb", str(anchor), "--fit", str(fit),
                            "--checker", checker], gate_path)
        return errors


def check(slots: Slots, anchor: pathlib.Path, keys: list[str], algo: str, bits: int,
          checker: str, gate_path: pathlib.Path) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="slot-fits-check-") as td:
        _, errors = slots.check_layout(pathlib.Path(td))
    return errors + slots.check_trust(anchor, keys, algo, bits, checker, gate_path)


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sign(slots: Slots, anchor: pathlib.Path, keys: list[str], algo: str, bits: int,
         key_name: str, sign_one: Callable[[pathlib.Path], dict], checker: str,
         gate_path: pathlib.Path, force: bool = False,
         manifest: Optional[pathlib.Path] = None) -> dict:
    """Sign both FITs with the profile key or leave both untouched."""
    with tempfile.TemporaryDirectory(prefix="slot-fits-sign-") as td:
        work = pathlib.Path(td)
        before, errors = slots.check_layout(work)
        if errors:
            raise SlotFitError("refusing to sign:\n  " + "\n  ".join(errors))
        prof = profile_anchor(anchor, key_name, work / "profile-anchor.dtb")

        def verified_by_profile(fit: pathlib.Path) -> bool:
            return not gate(["fit", "--dtb", str(prof), "--fit", str(fit),
                             "--checker", checker], gate_path)

        results, todo = {}, []
        for slot, fit in slots.fits.items():
            hints = key_name_hints(fit)
            if (not force and hints and all(h == key_name for h in hints)
                    and verified_by_profile(fit)):
                results[slot] = "skipped (already signed by this key)"
            else:
                todo.append(slot)
        # Every backup is complete before any FIT is touched, and only a
        # complete backup is ever restored: a failed copy aborts with both
        # FITs still as they were.
        backups = {}
        for slot in todo:
            b = work / f"{slots.fits[slot].name}.orig"
            shutil.copy2(slots.fits[slot], b)
            backups[slot] = b
        try:
            for slot in todo:
                fit = slots.fits[slot]
                sign_one(fit)
                after, errs = fit_bootargs(fit, work)
                if errs or after != before[slot]:
                    raise SlotFitError(f"slot {slot}: command line changed by signing")
                if not verified_by_profile(fit):
                    raise SlotFitError(f"slot {slot}: does not verify against key-{key_name} after signing")
                results[slot] = "signed"
            final = slots.check_trust(anchor, keys, algo, bits, checker, gate_path)
            if final:
                raise SlotFitError("signed FITs fail the anchor gate:\n  " + "\n  ".join(final))
        except BaseException:
            for slot, b in backups.items():
                shutil.copy2(b, slots.fits[slot])
            raise
    summary = {
        "key_name_hint": key_name,
        "root_hash": slots.params["VERITY_ROOT_HASH"],
        "slots": {s: {"file": str(f), "result": results[s], "sha256": _sha256(f)}
                  for s, f in slots.fits.items()},
        "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }
    if manifest:
        manifest.write_text(json.dumps(summary, indent=2) + "\n")
    return summary


# ------------------------------------------------------------------- CLI

def add_slot_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--image", required=True,
                   help="image link name the bundle ships, e.g. iot-gw-image-prod-raspberrypi5")
    p.add_argument("--deploy-dir", required=True)
    p.add_argument("--archive", required=True,
                   help="bootfiles archive the bundle ships; its DTB is the trust anchor")
    p.add_argument("--anchor-member", default=DEFAULT_ANCHOR_MEMBER)
    p.add_argument("--keys", nargs="+",
                   help="every trust root the anchor must hold, without the key- prefix "
                        "(default: the keys the anchor holds; the bundle gate always passes "
                        "the build's enabled roots)")
    p.add_argument("--algo", default="sha256,rsa2048")
    p.add_argument("--bits", default=2048, type=int)
    p.add_argument("--slot-a-device", default=DEFAULT_SLOT_DEVICES["A"])
    p.add_argument("--slot-b-device", default=DEFAULT_SLOT_DEVICES["B"])
    p.add_argument("--fit-a", help="override the A file (staged bundle copy)")
    p.add_argument("--fit-b", help="override the B file (staged bundle copy)")
    p.add_argument("--rootfs", help="override the rootfs file (staged bundle copy)")
    p.add_argument("--checker", default=shutil.which("fit_check_sign") or "fit_check_sign")
    p.add_argument("--gate", default=str(DEFAULT_GATE))


def slots_from_args(a: argparse.Namespace) -> Slots:
    opt = lambda v: pathlib.Path(v) if v else None
    return Slots(pathlib.Path(a.deploy_dir), a.image, rootfs=opt(a.rootfs),
                 fit_a=opt(a.fit_a), fit_b=opt(a.fit_b),
                 devices={"A": a.slot_a_device, "B": a.slot_b_device})


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    add_slot_args(sub.add_parser("check", help="verify an A/B pair; signs nothing"))
    a = p.parse_args(argv)
    try:
        slots = slots_from_args(a)
        with tempfile.TemporaryDirectory(prefix="slot-fits-anchor-") as td:
            anchor = anchor_from_archive(pathlib.Path(a.archive), a.anchor_member, pathlib.Path(td))
            errors = check(slots, anchor, a.keys or anchor_keys(anchor), a.algo, a.bits,
                           a.checker, pathlib.Path(a.gate))
    except SlotFitError as e:
        errors = [str(e)]
    for e in errors:
        print("slot FITs: " + e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
