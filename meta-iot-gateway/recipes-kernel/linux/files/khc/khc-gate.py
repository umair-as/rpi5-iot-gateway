#!/usr/bin/env python3
"""Kernel-hardening gate: run kernel-hardening-checker on a resolved kernel
.config and compare its FAIL rows with a committed per-board baseline.

The baseline maps every accepted failing option to the reason it is accepted.
An empty or missing reason is not a reason. The baseline also records the
checker version that produced it, because the rule set changes between
versions; a run with another version is not comparable.

Modes:
  default        gate: exit 1 on a FAIL outside the baseline, on an entry
                 without a reason, or on a checker-version mismatch.
  --report-only  same comparison, same report, but the outcome never fails
                 (exit 0). Only a tool or usage error exits non-zero.
  --propose F    also write a baseline proposal to F: every current FAIL,
                 keeping the reasons the existing baseline already gives and
                 an empty reason for the rest. A human fills the reasons in
                 and commits it as the baseline.

The input must be the expanded .config produced by the kernel configure step
(it starts with "# Linux/<arch> <version> Kernel Configuration"). A defconfig
or a .cfg fragment does not carry the arch, the version or Kconfig defaults.

Exit codes: 0 pass (or --report-only), 1 gate failure, 2 usage or tool error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOL = "kernel-hardening-checker"


def die(msg: str) -> None:
    print(f"[khc-gate] ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def checker_cmd(tool: str) -> list[str]:
    """Run a Python entry script with this interpreter. A native Yocto install
    carries a nativepython3 shebang that is only on PATH in python3native
    recipes; the interpreter running this gate shares that sysroot."""
    try:
        with open(tool, "rb") as fh:
            first = fh.readline()
    except OSError:
        return [tool]
    return [sys.executable, tool] if first.startswith(b"#!") and b"python" in first else [tool]


def tool_version(tool: str) -> str:
    out = subprocess.run([*checker_cmd(tool), "--version"], capture_output=True, text=True, check=False)
    text = (out.stdout or out.stderr).strip()
    return text.split()[-1] if text else "unknown"


def run_checker(tool: str, config: Path) -> list[dict]:
    proc = subprocess.run([*checker_cmd(tool), "-c", str(config), "-m", "json"],
                          capture_output=True, text=True, check=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        die(f"{tool} failed (rc={proc.returncode}): {proc.stderr.strip()}")
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        die(f"cannot parse checker JSON: {exc}")
    if not isinstance(rows, list):
        die("checker JSON is not a list")
    return rows


def has_reason(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def read_baseline(path: Path) -> tuple[dict[str, str], str | None]:
    if not path.is_file():
        return {}, None
    data = json.loads(path.read_text())
    accepted = data.get("accepted_failures")
    if not isinstance(accepted, dict):
        die(f"{path}: 'accepted_failures' must map option name to reason")
    return accepted, data.get("tool_version")


def write_baseline(path: Path, accepted: dict[str, str], config: Path, version: str) -> None:
    data = {
        "_comment": "Options kernel-hardening-checker reports as FAIL that this board "
                    "accepts, each with its reason. An empty reason is not accepted.",
        "tool": TOOL,
        "tool_version": version,
        "config": config.name,
        "generated": dt.date.today().isoformat(),
        "accepted_failures": dict(sorted(accepted.items())),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True, type=Path, help="resolved kernel .config")
    ap.add_argument("--baseline", required=True, type=Path, help="accepted-failures JSON")
    ap.add_argument("--report", type=Path, help="write a markdown report here")
    ap.add_argument("--propose", type=Path, help="write a baseline proposal here")
    ap.add_argument("--report-only", action="store_true", help="never fail on the comparison")
    ap.add_argument("--checker", default=TOOL, help="checker executable (default: on PATH)")
    args = ap.parse_args()

    tool = shutil.which(args.checker)
    if tool is None:
        die(f"{args.checker} not found")
    if not args.config.is_file():
        die(f"config {args.config} not found")

    version = tool_version(tool)
    rows = run_checker(tool, args.config)
    fails = {r["option_name"]: r.get("check_result", "FAIL")
             for r in rows if not r.get("check_result_bool", False)}
    ok = len(rows) - len(fails)

    accepted, recorded = read_baseline(args.baseline)
    problems: list[str] = []
    if recorded is None:
        problems.append(f"no baseline at {args.baseline}")
    elif recorded != version:
        problems.append(f"baseline recorded with {TOOL} {recorded}, this run uses {version}")
    unreasoned = sorted(k for k, v in accepted.items() if not has_reason(v))
    if unreasoned:
        problems.append(f"{len(unreasoned)} baseline entries without a reason")
    regressions = {k: v for k, v in fails.items() if k not in accepted}
    fixed = sorted(set(accepted) - set(fails))

    if args.propose:
        proposal = {k: (accepted[k] if has_reason(accepted.get(k)) else "") for k in fails}
        write_baseline(args.propose, proposal, args.config, version)

    if args.report:
        lines = [
            f"# kernel-hardening-checker: `{args.config.name}`",
            "",
            f"- tool: {TOOL} {version}; baseline: {args.baseline.name} ({recorded or 'absent'})",
            f"- checks: {len(rows)}; OK: {ok}; FAIL: {len(fails)}; accepted: {len(accepted)}",
            f"- not in baseline: {len(regressions)}; accepted but now passing: {len(fixed)}",
            "",
        ]
        if problems:
            lines += ["## Baseline problems", ""] + [f"- {p}" for p in problems] + [""]
        if regressions:
            lines += ["## FAIL not in baseline", ""]
            lines += [f"- `{k}`: {v}" for k, v in sorted(regressions.items())] + [""]
        if fixed:
            lines += ["## Accepted but now passing (drop from baseline)", ""]
            lines += [f"- `{k}`" for k in fixed] + [""]
        lines += ["## Accepted failures", ""]
        lines += [f"- `{k}`: {accepted[k] or '(no reason)'}" for k in sorted(accepted)] + [""]
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text("\n".join(lines))

    print(f"[khc-gate] {args.config.name}: {len(rows)} checks, {ok} OK, {len(fails)} FAIL, "
          f"{len(regressions)} not in baseline, {len(fixed)} newly passing ({TOOL} {version})")
    for p in problems:
        print(f"[khc-gate] baseline: {p}")
    for k, v in sorted(regressions.items()):
        print(f"[khc-gate]   not in baseline: {k}: {v}")

    if args.report_only:
        return 0
    return 1 if (problems or regressions) else 0


if __name__ == "__main__":
    sys.exit(main())
