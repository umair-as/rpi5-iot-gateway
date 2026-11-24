#!/usr/bin/env python3
"""Map changed paths to the cheapest check that exercises them.

Run before starting an image build. A policy, fragment or script defect
caught here costs seconds or minutes; caught by the image build it costs
the whole build.

Two tiers:
  host     pytest suites and source checks. No BitBake. Always run.
  bitbake  one targeted task per affected area (refpolicy compile, kernel
           configure, or a parse). Run only with --bitbake. Refused while
           another build holds the build directory: BitBake takes
           build/bitbake.lock, and agent-build.py holds
           build/.agent-build.lock for its whole run.

Changed paths default to everything since the merge base with origin/main
(else main): the branch's commits, uncommitted changes and untracked files.
--base REF compares against REF instead; --paths takes an explicit list.

Usage:
  scripts/preflight/preflight.py [--plan] [--bitbake] [--base REF] [--paths P ...]

Exit status: 0 all selected checks passed (or --plan), 1 a check failed,
3 --bitbake refused because the build directory is busy.
"""

import argparse
import fcntl
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

REPO = pathlib.Path(__file__).resolve().parents[2]
LAYER = "meta-iot-gateway/"
POLICY_DIR = LAYER + "recipes-security/refpolicy/files/policy/"


@dataclass(frozen=True)
class Check:
    key: str
    tier: str  # "host" or "bitbake"
    what: str
    cmds: tuple  # tuple of argv tuples


def make(*args):
    return ("make", "--no-print-directory", *args)


# The bitbake tier runs fixed BitBake commands in the default (dev)
# composition: `kas shell <stack> -c <command>`, with the stack from
# `make stack`. Commands are built here from fixed text and recipe names that
# pass PN_RE, never from free text.
KAS_SHELL = "kas-shell"
PN_RE = re.compile(r"^[a-z0-9][a-z0-9.+_-]*$")


def kas_task(command):
    return (KAS_SHELL, command)


CHECKS = {
    c.key: c for c in (
        Check("selinux-policy", "host",
              "raw-rule types declared or gen_require'd (iotgw.te/.if)",
              (("python3", "scripts/selinux/policy-raw-type-check.py",
                POLICY_DIR + "iotgw.te", POLICY_DIR + "iotgw.if"),
               make("test", "SUITE=selinux"))),
        Check("kernel-fragment-gate", "host", "kernel fragment gate tests",
              (make("test", "SUITE=kernel"),)),
        Check("boot-scripts", "host", "OTA/preinit/sshd script tests",
              (make("test", "SUITE=boot"),)),
        Check("sbom-cve", "host", "sbom-cve reader tests",
              (make("test", "SUITE=sbom-cve"),)),
        Check("sign-fit", "host", "FIT signing tool tests",
              (make("test", "SUITE=sign-fit"),)),
        Check("agent-build", "host", "agent-build launcher dummy-job tests",
              (("python3", "scripts/agent-build/test-agent-build.py"),)),
        Check("preflight", "host", "preflight mapping tests",
              (make("test", "SUITE=preflight"),)),
        Check("host-tools", "host", "TPM store and SSH helper tests",
              (make("test", "SUITE=host-tools"),)),
        Check("tooling", "host", "commit-msg hook, make shell/stack and preflight command tests",
              (make("test", "SUITE=tooling"),)),
        Check("refpolicy-compile", "bitbake",
              "refpolicy-mcs do_compile (checkmodule on the iotgw module)",
              (kas_task("bitbake refpolicy-mcs -c compile"),)),
        Check("kernel-configure", "bitbake",
              "kernel do_configure (fragment merge + keep-block gate)",
              (kas_task("bitbake virtual/kernel -c configure"),)),
        Check("recipe-patch", "bitbake",
              "do_patch on the touched recipes (SRC_URI files present, patches apply)",
              ()),  # argv built per run from the touched recipes
        Check("parse", "bitbake", "bitbake -p over the full layer set",
              (make("parse"),)),
    )
}

BOOT_SCRIPTS = {
    LAYER + "recipes-ota/rauc/files/bundle-hooks-fit.sh",
    LAYER + "recipes-support/iotgw-preinit/files/iotgw-preinit.sh",
    LAYER + "recipes-connectivity/openssh/files/iotgw-sshd-keys.sh",
}
# Host helpers that log in to a gateway through scripts/lib/host-ssh.sh.
HOST_SSH_SCRIPTS = {
    "scripts/run-target-checks.sh",
    "scripts/deepx/dxm1-push-model.sh",
    "scripts/selinux/policy-trial.sh",
}
METADATA_SUFFIXES = (".bb", ".bbappend", ".bbclass", ".inc", ".conf")
# Recipe directories with their own targeted task above, or none to patch.
RECIPE_DIRS_COVERED = (
    LAYER + "recipes-security/refpolicy/",
    LAYER + "recipes-kernel/linux/",
    LAYER + "recipes-core/images/",
)
RECIPE_DIR_RE = re.compile(r"^(" + re.escape(LAYER) + r"recipes-[^/]+/[^/]+)/")


def recipe_names(path):
    """PNs of the .bb/.bbappend files in the recipe directory holding path."""
    if path.startswith(RECIPE_DIRS_COVERED):
        return set()
    m = RECIPE_DIR_RE.match(path)
    if not m:
        return set()
    d = REPO / m.group(1)
    names = set()
    for f in list(d.glob("*.bb")) + list(d.glob("*.bbappend")):
        names.add(re.split(r"[_%]", f.name.rsplit(".", 1)[0], maxsplit=1)[0])
    # Packagegroups have no source to unpack or patch; parse covers them.
    return {n for n in names if not n.startswith("packagegroup-")}


def classify(path):
    """Check keys that exercise one changed path."""
    keys = set()
    p = path
    if p.startswith(LAYER + "recipes-security/refpolicy/"):
        keys |= {"selinux-policy", "refpolicy-compile"}
    if p.startswith("scripts/selinux/"):
        keys.add("selinux-policy")
    if (p.startswith(LAYER + "recipes-kernel/linux/")
            or p == LAYER + "classes/iotgw-kernel-fragments.bbclass"
            or p.startswith("scripts/kernel/")):
        keys |= {"kernel-fragment-gate", "kernel-configure"}
    if p in BOOT_SCRIPTS or p.startswith(("scripts/ota/", "scripts/preinit/", "scripts/sshd/")):
        keys.add("boot-scripts")
    if p.startswith("scripts/sbom-cve/"):
        keys.add("sbom-cve")
    if p.startswith("scripts/fit-signing/"):
        keys.add("sign-fit")
    if p.startswith("scripts/agent-build/"):
        keys.add("agent-build")
    if p.startswith("scripts/preflight/"):
        keys.add("preflight")
    if p.startswith(("scripts/tpm/", "scripts/lib/")) or p in HOST_SSH_SCRIPTS:
        keys.add("host-tools")
    if p.startswith(("scripts/hooks/", "scripts/tests/")) or p == "Makefile":
        keys.add("tooling")
    if recipe_names(p):
        keys.add("recipe-patch")
    if (p.endswith(METADATA_SUFFIXES) and p.startswith(LAYER)) \
            or (p.startswith("kas/") and p.endswith(".yml")) or p == "rpi5.yml":
        keys.add("parse")
    return keys


def changed_paths(base):
    def git(*args):
        out = subprocess.run(("git", *args), cwd=REPO, check=True,
                             capture_output=True, text=True).stdout
        return [line for line in out.splitlines() if line]

    if not base:
        base = "HEAD"
        for ref in ("origin/main", "main"):
            probe = subprocess.run(
                ("git", "rev-parse", "--quiet", "--verify", ref + "^{commit}"),
                cwd=REPO,
                capture_output=True,
                check=False,
            )
            if probe.returncode == 0:
                base = git("merge-base", ref, "HEAD")[0]
                break
    # git diff <commit> compares that commit with the working tree: committed
    # and uncommitted changes alike.
    paths = git("diff", "--name-only", "--no-renames", base)
    paths += git("ls-files", "--others", "--exclude-standard")
    return sorted(set(paths))


def shell_syntax_targets(paths):
    """Changed shell scripts, by suffix or shebang, that still exist."""
    out = []
    for p in paths:
        f = REPO / p
        if not f.is_file():
            continue
        try:
            first = f.open("rb").readline()
        except OSError:
            continue
        if p.endswith(".sh") or first.startswith((b"#!/bin/sh", b"#!/bin/bash",
                                                    b"#!/usr/bin/env bash", b"#!/usr/bin/env sh")):
            shell = "bash" if b"bash" in first else "sh"
            out.append((shell, p))
    return out


def lock_held(path):
    """True if another process holds an flock on path (absent file: False)."""
    try:
        fh = path.open("r")
    except FileNotFoundError:
        return False
    with fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(fh, fcntl.LOCK_UN)
    return False


def build_dir_busy():
    """Reason the build directory is in use, or None.

    Both locks are probed with flock, not by existence: bitbake.lock is
    left behind after a clean exit (hence `make clean-lock`), and a stale
    file must not block the tier.
    """
    build = pathlib.Path(os.environ.get("KAS_BUILD_DIR", REPO / "build"))
    if lock_held(build / ".agent-build.lock"):
        return f"{build.name}/.agent-build.lock is held (an agent-build.py run is active)"
    if lock_held(build / "bitbake.lock"):
        return f"{build.name}/bitbake.lock is held (a BitBake server is running)"
    return None


def run(argv):
    if argv[0] == KAS_SHELL:
        stack = subprocess.run(make("-s", "stack"), cwd=REPO, check=True,
                               capture_output=True, text=True).stdout.strip()
        argv = (os.environ.get("KAS", "kas"), "shell", stack, "-c", argv[1])
    print("  $ " + " ".join(argv), flush=True)
    return subprocess.run(argv, cwd=REPO).returncode


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--plan", action="store_true", help="print the plan, run nothing")
    ap.add_argument("--bitbake", action="store_true", help="also run the bitbake tier")
    ap.add_argument("--base", help="compare against REF instead of the merge base with main")
    ap.add_argument("--paths", nargs="+", help="explicit changed paths (repo-relative)")
    args = ap.parse_args(argv)

    paths = sorted(set(args.paths)) if args.paths else changed_paths(args.base)
    selected, unmapped = {}, []
    for p in paths:
        keys = classify(p)
        if not keys and not p.startswith("docs/") and not p.endswith(".md"):
            unmapped.append(p)
        for k in keys:
            selected.setdefault(k, []).append(p)
    # Any targeted bitbake task parses the whole layer set first.
    if "parse" in selected and {"refpolicy-compile", "kernel-configure",
                                "recipe-patch"} & selected.keys():
        selected.pop("parse")
    shells = shell_syntax_targets(paths)

    checks = dict(CHECKS)
    if "recipe-patch" in selected:
        pns = sorted(set().union(*(recipe_names(p) for p in selected["recipe-patch"])))
        bad = [pn for pn in pns if not PN_RE.match(pn)]
        if bad:
            raise SystemExit(f"preflight: refusing unexpected recipe names: {bad}")
        checks["recipe-patch"] = Check(
            "recipe-patch", "bitbake", CHECKS["recipe-patch"].what + ": " + " ".join(pns),
            (kas_task("bitbake " + " ".join(pns) + " -c patch"),))
        if len(pns) > 10:
            print(f"note: do_patch spans {len(pns)} recipes and recreates their WORKDIRs; "
                  "narrow with --base REF or --paths")
    host = [checks[k] for k in checks if k in selected and checks[k].tier == "host"]
    bb = [checks[k] for k in checks if k in selected and checks[k].tier == "bitbake"]

    print(f"preflight: {len(paths)} changed path(s)")
    if not paths and not args.paths:
        print(
            "  WARNING: no changed paths, so nothing is checked; give --base REF or --paths"
        )
    for c in host + bb:
        n = len(selected[c.key])
        print(f"  [{c.tier:7}] {c.key:22} {c.what}  ({n} path(s), e.g. {selected[c.key][0]})")
    if shells:
        print(f"  [host   ] {'shell-syntax':22} sh/bash -n on {len(shells)} changed script(s)")
    if unmapped:
        print(f"  no fast check for {len(unmapped)} path(s); only an image build covers them:")
        for p in unmapped[:15]:
            print(f"    {p}")
        if len(unmapped) > 15:
            print(f"    ... {len(unmapped) - 15} more")
    if bb and not args.bitbake:
        print("  bitbake tier not run (pass --bitbake, or PREFLIGHT_ARGS=--bitbake via make)")
    if args.plan:
        return 0

    failed = []
    for shell, p in shells:
        if subprocess.run((shell, "-n", p), cwd=REPO).returncode != 0:
            failed.append(f"shell-syntax:{p}")
    for c in host:
        print(f"\n== {c.key}", flush=True)
        if any(run(list(cmd)) != 0 for cmd in c.cmds):
            failed.append(c.key)

    if args.bitbake and bb:
        busy = build_dir_busy()
        if busy:
            print(f"\npreflight: bitbake tier refused: {busy}", file=sys.stderr)
            print("  Coordinate with whoever owns the build; never remove the lock.", file=sys.stderr)
            return 3
        for c in bb:
            print(f"\n== {c.key}", flush=True)
            if any(run(list(cmd)) != 0 for cmd in c.cmds):
                failed.append(c.key)

    print("\npreflight: " + ("FAILED: " + ", ".join(failed) if failed else "all selected checks passed"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
