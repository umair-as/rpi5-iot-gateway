"""Tests for report-vs-report and report-vs-vulns.git verdict comparison.

Synthetic reports and a synthetic vulns.git tree only; no Yocto build and no
real CVE data required.
"""
import json
import pathlib
import subprocess
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import cve_compare  # noqa: E402

SBOM_DIR = pathlib.Path(cve_compare.__file__).resolve().parent
KERNEL = "linux-iotgw-mainline"


def report(packages):
    """cve-check report: {package: {cve: (status, detail)}}."""
    return {"version": "1", "package": [
        {"name": name, "version": "1.0", "issue": [
            {"id": cve, "status": st, "detail": det}
            for cve, (st, det) in issues.items()]}
        for name, issues in packages.items()]}


def write_report(path, packages):
    path.write_text(json.dumps(report(packages)))
    return path


def make_vulns(root, dyads, rejected=()):
    """vulns.git layout: cve/published/<year>/<id>.dyad, cve/rejected/<year>/."""
    for cve, lines in dyads.items():
        d = root / "cve" / "published" / cve.split("-")[1]
        d.mkdir(parents=True, exist_ok=True)
        (d / (cve + ".dyad")).write_text(
            "# dyad version: test\n" + "".join(l + "\n" for l in lines))
    for cve in rejected:
        d = root / "cve" / "rejected" / cve.split("-")[1]
        d.mkdir(parents=True, exist_ok=True)
        (d / (cve + ".json")).write_text("{}")
    return root


def pair(intro, fixed):
    return "%s:%s:%s:%s" % (intro, "a" * 40 if intro != "0" else "0",
                            fixed, "b" * 40 if fixed != "0" else "0")


# --- report diff -----------------------------------------------------------

def test_package_rows_selects_named_package():
    data = report({KERNEL: {"CVE-2024-1": ("Patched", "fixed-version: x")},
                   "busybox": {"CVE-2024-2": ("Unpatched", "")}})
    assert cve_compare.package_rows(data, KERNEL) == {
        "CVE-2024-1": ("Patched", "fixed-version: x")}
    assert list(cve_compare.package_rows(data, "busybox")) == ["CVE-2024-2"]


def test_package_rows_missing_package_fails():
    with pytest.raises(SystemExit):
        cve_compare.package_rows(report({"busybox": {}}), KERNEL)


def test_diff_both_directions_and_absent_rows():
    a = {"CVE-2024-1": ("Patched", "fixed-version: Fixed from 6.1"),
         "CVE-2024-2": ("Unpatched", "version-in-range"),
         "CVE-2024-3": ("Ignored", "disputed"),
         "CVE-2024-4": ("Patched", "cpe-stable-backport: x")}
    b = {"CVE-2024-1": ("Unpatched", "version-in-range"),
         "CVE-2024-2": ("Patched", "fixed-version: y"),
         "CVE-2024-4": ("Patched", "cpe-stable-backport: x"),
         "CVE-2024-5": ("Unpatched", "version-in-range")}
    moved, trans = cve_compare.diff_package(a, b)
    assert [m[0] for m in moved] == [
        "CVE-2024-1", "CVE-2024-2", "CVE-2024-3", "CVE-2024-5"]
    assert ("CVE-2024-3", "Ignored", "disputed", "ABSENT", "") in moved
    assert ("CVE-2024-5", "ABSENT", "", "Unpatched", "version-in-range") in moved
    assert trans[("Patched", "fixed-version", "Unpatched", "version-in-range")] == 1
    assert trans[("Unpatched", "version-in-range", "Patched", "fixed-version")] == 1


def test_diff_detail_only_change_is_reported():
    a = {"CVE-2024-1": ("Patched", "fixed-version: Fixed from 6.1")}
    b = {"CVE-2024-1": ("Patched", "fixed-version: Fixed from 6.2")}
    moved, _ = cve_compare.diff_package(a, b)
    assert len(moved) == 1 and moved[0][1] == moved[0][3]


def test_diff_orders_cves_numerically():
    rows = {"CVE-2024-10000": ("Patched", ""), "CVE-2024-999": ("Patched", ""),
            "CVE-2023-50000": ("Patched", "")}
    moved, _ = cve_compare.diff_package(rows, {})
    assert [m[0] for m in moved] == [
        "CVE-2023-50000", "CVE-2024-999", "CVE-2024-10000"]


def test_cli_diff_writes_tsv(tmp_path):
    old = write_report(tmp_path / "old.json", {
        KERNEL: {"CVE-2024-1": ("Patched", "fixed-version: a")},
        "other": {"CVE-2024-9": ("Patched", "")}})
    new = write_report(tmp_path / "new.json", {
        KERNEL: {"CVE-2024-1": ("Unpatched", "version-in-range")},
        "other": {"CVE-2024-9": ("Unpatched", "")}})
    tsv = tmp_path / "moved.tsv"
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "diff",
         str(old), str(new), "--labels", "A", "B", "--tsv", str(tsv)],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "moved rows A->B: 1" in r.stdout
    assert "status-changing: 1" in r.stdout
    assert tsv.read_text().splitlines() == [
        "cve\tA_status\tA_detail\tB_status\tB_detail",
        "CVE-2024-1\tPatched\tfixed-version: a\tUnpatched\tversion-in-range"]


def test_cli_diff_package_flag(tmp_path):
    old = write_report(tmp_path / "old.json", {
        KERNEL: {}, "other": {"CVE-2024-9": ("Patched", "")}})
    new = write_report(tmp_path / "new.json", {
        KERNEL: {}, "other": {"CVE-2024-9": ("Unpatched", "")}})
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "diff",
         str(old), str(new), "--package", "other"],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "moved rows old->new: 1" in r.stdout


# --- vulns.git dyad oracle -------------------------------------------------

@pytest.mark.parametrize("version,expected", [
    ("6.18.59", ((6, 18), 59)),
    ("6.13", ((6, 13), None)),
    ("6.13-rc1", ((6, 13), None)),
    ("6.18.59+gitAUTOINC+1253a6aa5d_307ef96123", ((6, 18), 59)),
])
def test_parse_kernel_version(version, expected):
    assert cve_compare.parse_kernel_version(version) == expected


def test_parse_kernel_version_rejects_garbage():
    with pytest.raises(ValueError):
        cve_compare.parse_kernel_version("latest")


@pytest.mark.parametrize("version,inside", [
    ("6.12", True),        # earlier mainline release
    ("6.18", True),        # own mainline base
    ("6.19", False),       # later mainline release
    ("6.18.59", True),     # same stable release
    ("6.18.12", True),     # earlier on the same branch
    ("6.18.60", False),    # later on the same branch
    ("6.12.9", False),     # other stable branch: not an ancestor
    ("5.10.215", False),
])
def test_contains(version, inside):
    assert cve_compare.contains("6.18.59", version) is inside


@pytest.fixture
def vulns(tmp_path):
    return make_vulns(tmp_path / "vulns", {
        # fixed on our branch by a stable backport
        "CVE-2025-0001": [pair("6.6", "6.18.40"), pair("6.6", "6.19")],
        # fixed in a mainline release we contain
        "CVE-2025-0002": [pair("6.1", "6.12")],
        # introduced in mainline before us, fixed only later
        "CVE-2025-0003": [pair("6.15", "6.19")],
        # introduced as a stable-only backport into another branch
        "CVE-2025-0004": [pair("5.10.215", "5.10.220"), pair("6.19", "6.20")],
        # unfixed anywhere, introduced before git history ("0")
        "CVE-2025-0005": [pair("0", "0")],
        # fixed on our branch only after our release
        "CVE-2025-0006": [pair("6.18", "6.18.60"), pair("6.18", "6.19")],
    }, rejected=["CVE-2025-0007"])


@pytest.mark.parametrize("cve,verdict", [
    ("CVE-2025-0001", "fixed"),
    ("CVE-2025-0002", "fixed"),
    ("CVE-2025-0003", "AFFECTED"),
    ("CVE-2025-0004", "not-introduced"),
    ("CVE-2025-0005", "AFFECTED"),
    ("CVE-2025-0006", "AFFECTED"),
    ("CVE-2025-0007", "rejected"),
    ("CVE-2025-0008", "no-dyad"),
])
def test_dyad_verdicts(vulns, cve, verdict):
    assert cve_compare.dyad_verdict(str(vulns), "6.18.59", cve)[0] == verdict


def test_dyad_evidence_lists_pairs(vulns):
    _, ev = cve_compare.dyad_verdict(str(vulns), "6.18.59", "CVE-2025-0001")
    assert ev == "6.6->6.18.40 6.6->6.19"


def test_dyad_malformed_line_fails(tmp_path):
    root = make_vulns(tmp_path / "vulns", {"CVE-2025-0001": ["6.6:abc:6.19"]})
    with pytest.raises(ValueError):
        cve_compare.dyad_verdict(str(root), "6.18.59", "CVE-2025-0001")


def test_cli_dyad_reads_stdin(vulns):
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "dyad",
         "--vulns", str(vulns), "--kernel-version", "6.18.59"],
        input="CVE-2025-0002\nCVE-2025-0003\n", capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == [
        "CVE-2025-0002\tfixed\t6.1->6.12",
        "CVE-2025-0003\tAFFECTED\t6.15->6.19"]


def test_cli_dyad_bad_version_exits_nonzero(vulns):
    r = subprocess.run(
        [sys.executable, str(SBOM_DIR / "cve-report.py"), "dyad",
         "--vulns", str(vulns), "--kernel-version", "latest", "CVE-2025-0002"],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "not a kernel version" in r.stderr
