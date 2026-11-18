"""Compare CVE verdicts: report against report, and report against vulns.git.

Two independent views used when a change claims to move (or not move) CVE
rows, such as editing a recipe's CVE_STATUS set:

  diff_package  every CVE of one package whose (status, detail) differs
                between two cve-check reports, in both directions, including
                rows present in only one report.
  dyad_verdict  whether a kernel version carries a fix, read only from the
                kernel CNA's published .dyad files in a vulns.git clone,
                never from the scanner whose output is being checked.

Stdlib only; imported by cve-report.py (hyphenated, so not importable itself).
"""

import collections
import glob
import os

from cohort import die

ABSENT = "ABSENT"


def package_rows(data, package):
    """{cve: (status, detail)} for one package of a cve-check report."""
    hits = [p for p in data.get("package", []) if p.get("name") == package]
    if len(hits) != 1:
        die("expected exactly one package %r in report, found %d"
            % (package, len(hits)))
    return {i["id"]: (i.get("status", ""), i.get("detail", ""))
            for i in hits[0].get("issue", [])}


def cve_sort_key(cve):
    parts = cve.split("-")
    try:
        return (int(parts[1]), int(parts[2]), cve)
    except (IndexError, ValueError):
        return (0, 0, cve)


def diff_package(rows_a, rows_b):
    """Rows that differ between two package_rows() maps.

    Returns (moved, transitions): moved is a list of
    (cve, status_a, detail_a, status_b, detail_b) in CVE order; transitions
    counts (status_a, detail_class_a, status_b, detail_class_b), where the
    detail class is the part of the detail before the first ':'.
    """
    moved = []
    transitions = collections.Counter()
    for cve in sorted(set(rows_a) | set(rows_b), key=cve_sort_key):
        a = rows_a.get(cve, (ABSENT, ""))
        b = rows_b.get(cve, (ABSENT, ""))
        if a == b:
            continue
        transitions[(a[0], a[1].split(":")[0], b[0], b[1].split(":")[0])] += 1
        moved.append((cve, a[0], a[1], b[0], b[1]))
    return moved, transitions


def parse_kernel_version(version):
    """'6.18.59' -> ((6, 18), 59); '6.13' or '6.13-rc1' -> ((6, 13), None).

    Anything after '-' or '+' (rc tags, Yocto PV git suffixes) is dropped.
    """
    base = version.split("+")[0].split("-")[0]
    try:
        parts = [int(x) for x in base.split(".")]
    except ValueError:
        raise ValueError("not a kernel version: %r" % version)
    if len(parts) < 2:
        raise ValueError("not a kernel version: %r" % version)
    return tuple(parts[:2]), (parts[2] if len(parts) > 2 else None)


def contains(target, version):
    """Is `version` part of the history of the stable release `target`?

    A mainline release is an ancestor of every later branch. A stable release
    is an ancestor only within its own branch: a fix landed as 5.10.215 is a
    backport into 5.10.y alone, and mainline carriers get their own dyad pair.
    """
    t_branch, t_sub = parse_kernel_version(target)
    branch, sub = parse_kernel_version(version)
    if sub is None:
        return branch <= t_branch
    if branch == t_branch:
        return t_sub is not None and sub <= t_sub
    return False


def dyad_verdict(vulns_dir, target, cve):
    """(verdict, evidence) for one CVE against kernel version `target`.

    verdict: fixed | not-introduced | AFFECTED | rejected | no-dyad.
    Reads only cve/published/<year>/<CVE>.dyad and cve/rejected/<year>/.
    """
    parts = cve.split("-")
    if len(parts) < 3:
        raise ValueError("not a CVE id: %r" % cve)
    year = parts[1]
    if glob.glob(os.path.join(vulns_dir, "cve", "rejected", year,
                              glob.escape(cve) + "*")):
        return "rejected", ""
    path = os.path.join(vulns_dir, "cve", "published", year, cve + ".dyad")
    if not os.path.exists(path):
        return "no-dyad", ""
    pairs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # <introduced>:<introducing sha>:<fixed>:<fixing sha>; "0" = none
            fields = line.split(":")
            if len(fields) != 4:
                raise ValueError("%s: malformed dyad line %r" % (path, line))
            pairs.append((fields[0], fields[2]))
    evidence = " ".join("%s->%s" % p for p in pairs)
    if any(fixed != "0" and contains(target, fixed) for _, fixed in pairs):
        return "fixed", evidence
    if any(intro == "0" or contains(target, intro) for intro, _ in pairs):
        return "AFFECTED", evidence
    return "not-introduced", evidence
