#!/usr/bin/env python3
"""FIT trust gate: check the U-Boot anchor DTB and the FITs an image ships.

anchor  The board DTB U-Boot verifies FITs against. Its /signature/key-* nodes
        must be exactly the trust roots the build enabled (--keys): a missing
        one means a root was silently skipped, an extra one means a key the
        build did not ask for is trusted. Every key must be required="conf"
        (U-Boot ignores any other key, so an optional key lets an unsigned or
        foreign-signed FIT boot) and carry the expected algo and key size.
        With more than one key the /signature required-mode must be explicit.
fit     A finished FIT. Every configuration must carry a signature node and
        verify against the anchor with fit_check_sign.

Exit 0 when every check passes, 1 with one line per failure otherwise.
Needs fdtget (dtc) and, for `fit`, fit_check_sign on PATH or --checker.
"""
import argparse
import os
import subprocess
import sys


def fdtget(dtb, node, prop=None, list_nodes=False):
    cmd = ["fdtget"]
    if list_nodes:
        cmd += ["-l", dtb, node]
    else:
        cmd += [dtb, node, prop]
    run = subprocess.run(cmd, capture_output=True, text=True)
    if run.returncode != 0:
        return None
    return run.stdout.strip()


# Configuration properties that name an image the configuration boots.
IMAGE_REFS = ("kernel", "fdt", "ramdisk", "loadables", "firmware", "setup")


def check_anchor(args):
    errors = []
    expected = set(args.keys)
    nodes = fdtget(args.dtb, "/signature", list_nodes=True)
    keys = [n for n in (nodes or "").split() if n.startswith("key-")]
    if not keys:
        return ["%s: no /signature/key-* node; U-Boot would boot any FIT unverified"
                % args.dtb]
    present = {k[len("key-"):] for k in keys}
    for name in sorted(expected - present):
        errors.append("%s: trust root key-%s is enabled but absent (has: %s)"
                      % (args.dtb, name, " ".join(keys)))
    for name in sorted(present - expected):
        errors.append("%s: key-%s is trusted but not an enabled trust root (%s)"
                      % (args.dtb, name, " ".join(sorted(expected))))
    for key in keys:
        node = "/signature/%s" % key
        required = fdtget(args.dtb, node, "required")
        if required != "conf":
            errors.append("%s: %s required=%r, must be 'conf' (an optional key "
                          "lets unsigned and foreign-signed FITs boot)"
                          % (args.dtb, key, required))
        algo = fdtget(args.dtb, node, "algo")
        if algo != args.algo:
            errors.append("%s: %s algo=%r, expected %r" % (args.dtb, key, algo, args.algo))
        bits = fdtget(args.dtb, node, "rsa,num-bits")
        if bits != str(args.bits):
            errors.append("%s: %s rsa,num-bits=%r, expected %s"
                          % (args.dtb, key, bits, args.bits))
    if len(keys) > 1:
        mode = fdtget(args.dtb, "/signature", "required-mode")
        if mode not in ("all", "any"):
            errors.append("%s: %d keys but /signature required-mode=%r; set "
                          "'all' or 'any' explicitly" % (args.dtb, len(keys), mode))
    return errors


def check_fit(args):
    errors = []
    confs = fdtget(args.fit, "/configurations", list_nodes=True)
    if not confs:
        return ["%s: no configurations" % args.fit]
    for conf in confs.split():
        node = "/configurations/%s" % conf
        subnodes = (fdtget(args.fit, node, list_nodes=True) or "").split()
        sigs = [s for s in subnodes if s.startswith("signature")]
        if not sigs:
            errors.append("%s: %s has no signature node" % (args.fit, conf))
            continue
        # A U-Boot without the CVE-2026-46728 fix trusts sign-images, so a
        # signature that leaves out the fdt lets the device tree, and with it
        # the dm-verity root hash, be swapped. Check coverage here so the gate
        # does not depend on which fit_check_sign it is handed.
        for sig in sigs:
            signed = set((fdtget(args.fit, "%s/%s" % (node, sig), "sign-images") or "").split())
            for prop in sorted(p for p in IMAGE_REFS if fdtget(args.fit, node, p) is not None):
                if prop not in signed:
                    errors.append("%s: %s/%s sign-images %s leaves out %s"
                                  % (args.fit, conf, sig, sorted(signed) or "[]", prop))
        run = subprocess.run([args.checker, "-f", args.fit, "-k", args.dtb, "-c", conf],
                             capture_output=True, text=True)
        if run.returncode != 0:
            last = (run.stdout + run.stderr).strip().splitlines()[-3:]
            errors.append("%s: %s does not verify against %s: %s"
                          % (args.fit, conf, args.dtb, " | ".join(last)))
    return errors


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("anchor")
    a.add_argument("--dtb", required=True)
    a.add_argument("--keys", required=True, nargs="+",
                   help="names of every enabled trust root, without the key- prefix")
    a.add_argument("--algo", required=True, help="e.g. sha256,rsa2048")
    a.add_argument("--bits", required=True, type=int)
    f = sub.add_parser("fit")
    f.add_argument("--dtb", required=True)
    f.add_argument("--fit", required=True)
    f.add_argument("--checker", default="fit_check_sign")
    args = p.parse_args()
    missing = [f for f in (args.dtb, getattr(args, "fit", None)) if f and not os.path.isfile(f)]
    if missing:
        errors = ["%s: file not found" % f for f in missing]
    else:
        errors = check_anchor(args) if args.cmd == "anchor" else check_fit(args)
    for e in errors:
        print("FIT gate: " + e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
