#!/usr/bin/env python3
"""
Diagnose why sstate is not shared between two builds. Read-only throughout:
safe to run while a build is using the same trees and databases.

Subcommands:
  walk       compare two sigdata files with bitbake's own comparison; given
             each tree's stamps dir, recurse into the dependency whose hash
             changed until the root difference is reached
  sigdiff    raw field-by-field diff of two sigdata files (no recursion), for
             when walk's summary hides which value actually differs
  dbcompare  compare two hash-equivalence databases: for every
             (method, taskhash) present in both, do they hand out the same
             unihash; and how many identical outputs (outhash) both recorded

walk and sigdiff import bitbake's library (bb.siggen); dbcompare is
SQLite-only. See docs/SSTATE_SHARING.md for interpreting the results.

Usage:
  scripts/sstate/sigtool.py walk <sigA> <sigB> [--stamps-a DIR --stamps-b DIR]
  scripts/sstate/sigtool.py sigdiff <sigA> <sigB>
  scripts/sstate/sigtool.py dbcompare <hashserv-A.db> <hashserv-B.db>
"""

import argparse
import collections
import glob
import json
import os
import pathlib
import sqlite3
import sys

# kas checks bitbake out under .kas/ at the repo root.
DEFAULT_BB_LIB = pathlib.Path(__file__).resolve().parents[2] / ".kas" / "bitbake" / "lib"


def import_bitbake(lib):
    if not (pathlib.Path(lib) / "bb" / "siggen.py").is_file():
        sys.exit("error: no bitbake library at %s (pass --bitbake-lib)" % lib)
    sys.path.insert(0, str(lib))
    import bb.siggen  # noqa: F401
    import bb.compress.zstd  # noqa: F401
    return bb


def find_sigdata(stamps, key, unihash):
    """Locate a dependency's sigdata in a stamps tree by recipe, task, hash.

    `key` is "<recipe>:<task>" as bitbake reports a changed dependency; the
    recipe part may carry a path or virtual: prefix. Stamps are laid out as
    <stamps>/<pkgarch>/<PN>/<PV>-<PR>.<task>[_setscene].sigdata.<hash>.
    """
    recipe, task = key.rsplit(":", 1)
    pn = recipe.split("/")[-1]
    for pattern in ("*.%s.sig*data.%s", "*.%s_setscene.sig*data.%s"):
        hits = glob.glob(os.path.join(stamps, "*", pn, pattern % (task, unihash)))
        if hits:
            return hits[0]
    return None


def cmd_walk(args):
    bb = import_bitbake(args.bitbake_lib)
    recurse = None
    if args.stamps_a and args.stamps_b:
        def recurse(key, hash_a, hash_b):
            a = find_sigdata(args.stamps_a, key, hash_a)
            b = find_sigdata(args.stamps_b, key, hash_b)
            if not a or not b:
                return ["  [cannot recurse into %s: sigdata missing A=%s B=%s]"
                        % (key, bool(a), bool(b))]
            print("--> recursing into %s" % key)
            return bb.siggen.compare_sigfiles(a, b, recursecb=recurse)
    elif args.stamps_a or args.stamps_b:
        sys.exit("error: --stamps-a and --stamps-b go together")
    for line in bb.siggen.compare_sigfiles(args.sig_a, args.sig_b,
                                           recursecb=recurse):
        print(line)
    return 0


def cmd_sigdiff(args):
    bb = import_bitbake(args.bitbake_lib)

    def load(path):
        with bb.compress.zstd.open(path, "rt", encoding="utf-8",
                                   num_threads=1) as f:
            return json.load(f, object_hook=bb.siggen.SetDecoder)

    da, db = load(args.sig_a), load(args.sig_b)
    limit = args.max_keys
    for k in sorted(set(da) | set(db)):
        if k == "basehash_ignore_vars" or da.get(k) == db.get(k):
            continue
        va, vb = da.get(k), db.get(k)
        if isinstance(va, dict) and isinstance(vb, dict):
            keys = sorted(x for x in set(va) | set(vb) if va.get(x) != vb.get(x))
            print("%s: %d differing keys" % (k, len(keys)))
            for x in keys[:limit]:
                print("   %s\n      A= %s\n      B= %s"
                      % (x, str(va.get(x))[:300], str(vb.get(x))[:300]))
        else:
            print("%s:\n   A= %s\n   B= %s" % (k, str(va)[:300], str(vb)[:300]))
    return 0


def load_hashdb(path):
    if not os.path.isfile(path):
        sys.exit("error: no database at %s" % path)
    # mode=ro: never take a write lock on a database a build may be using.
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        uni = {(m, t): u for m, t, u in conn.execute(
            "SELECT method, taskhash, unihash FROM unihashes_v3")}
        outs = collections.defaultdict(set)
        for m, o, t in conn.execute(
                "SELECT method, outhash, taskhash FROM outhashes_v2"):
            outs[(m, o)].add(t)
    finally:
        conn.close()
    return uni, outs


def cmd_dbcompare(args):
    ua, oa = load_hashdb(args.db_a)
    ub, ob = load_hashdb(args.db_b)
    common = ua.keys() & ub.keys()
    same = sum(1 for k in common if ua[k] == ub[k])
    for label, path, uni, outs in (("A", args.db_a, ua, oa),
                                   ("B", args.db_b, ub, ob)):
        print("%s: %s\n   unihash rows %8d   outhash rows %8d"
              % (label, path, len(uni), sum(len(v) for v in outs.values())))
    print("taskhashes in both DBs:          %8d" % len(common))
    print("  ...same unihash in both:       %8d" % same)
    print("  ...DIFFERENT unihash:          %8d" % (len(common) - same))
    print("identical outputs (outhash) in both: %8d" % len(oa.keys() & ob.keys()))
    # Method is the task class (e.g. "oe.sstatesig.OEOuthashBasic").
    by_method = collections.Counter(
        k[0].split(".")[-1] for k in common if ua[k] != ub[k])
    print("methods with disagreement:", dict(by_method.most_common(5)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description="Diagnose sstate sharing: signatures and hash-equivalence DBs.")
    ap.add_argument("--bitbake-lib", default=str(DEFAULT_BB_LIB),
                    help="bitbake lib dir for walk/sigdiff (default: %(default)s)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("walk", help="bitbake signature comparison, recursive")
    w.add_argument("sig_a")
    w.add_argument("sig_b")
    w.add_argument("--stamps-a", help="stamps dir of tree A (enables recursion)")
    w.add_argument("--stamps-b", help="stamps dir of tree B (enables recursion)")
    w.set_defaults(func=cmd_walk)

    d = sub.add_parser("sigdiff", help="raw field-by-field sigdata diff")
    d.add_argument("sig_a")
    d.add_argument("sig_b")
    d.add_argument("--max-keys", type=int, default=12,
                   help="differing keys shown per dict field (default 12)")
    d.set_defaults(func=cmd_sigdiff)

    c = sub.add_parser("dbcompare", help="compare two hash-equivalence DBs")
    c.add_argument("db_a")
    c.add_argument("db_b")
    c.set_defaults(func=cmd_dbcompare)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
