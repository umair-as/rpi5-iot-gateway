#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Keep a local append-only decision trail; never execute verification commands."""

import argparse
import csv
import datetime as dt
import fcntl
import io
import json
import sys
from pathlib import Path

HEADER = ["ts", "actor", "phase", "decision", "why", "evidence", "result"]
RESULTS = ("PASS", "FAIL", "UNVERIFIED", "BLOCKED", "INFO")
CHECKPOINT = """# Handoff

Goal and requested milestone:

Worktree, branch, source revision and scoped dirty files:

Verified outcomes (command, result, source/artifact identity, evidence path):

Inherited claims and unverified axes:

Running builds (owner, run directory, log, attach command; preserve them):

Board / slot / image identity and serial owner (unknown until observed):

Authorization already given and operations still requiring approval:

Pending work, blockers and first permitted next action:

Decision trail: decisions.tsv
"""


def cell(value: str) -> str:
    """Keep TSV cells single-line and inert when opened in a spreadsheet."""
    value = " ".join(value.split())
    if not value:
        raise ValueError("decision fields must not be empty")
    return "'" + value if value[0] in "=+-@" else value


def validate(rows: list[list[str]], run: Path) -> None:
    if not rows or rows[0] != HEADER:
        raise ValueError("unexpected decisions.tsv header; leave history intact")
    for number, row in enumerate(rows[1:], 2):
        if len(row) != len(HEADER) or any(not item.strip() for item in row):
            raise ValueError(f"row {number}: missing fields")
        stamp = dt.datetime.fromisoformat(row[0])
        if stamp.utcoffset() is None:
            raise ValueError(f"row {number}: timestamp must include timezone")
        result = row[-1]
        if result not in RESULTS:
            raise ValueError(f"row {number}: unknown result {result}")
        paths = json.loads(row[-2])
        if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
            raise ValueError(f"row {number}: evidence must be a JSON list of paths")
        if result in ("PASS", "FAIL") and not paths:
            raise ValueError(f"row {number}: {result} requires an evidence file")
        for path in paths:
            if not (run / path).is_file():
                raise ValueError(f"row {number}: missing evidence file: {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser("init", help="create a new local run directory")
    initialize.add_argument("run", type=Path)
    record = commands.add_parser("record", help="append a decision, preserving history")
    record.add_argument("run", type=Path)
    for field in ("actor", "phase", "decision", "why"):
        record.add_argument(f"--{field}", required=True)
    record.add_argument(
        "--evidence",
        action="append",
        default=[],
        help="file path relative to run, or absolute; repeatable",
    )
    record.add_argument("--result", choices=RESULTS, required=True)
    check = commands.add_parser(
        "check", help="check trail structure and evidence paths, not claim truth"
    )
    check.add_argument("run", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "init":
            args.run.mkdir(parents=True, exist_ok=False)
            with (args.run / "decisions.tsv").open("x", newline="") as stream:
                csv.writer(stream, delimiter="\t").writerow(HEADER)
            (args.run / "checkpoint.md").write_text(CHECKPOINT)
            print(args.run)
            return 0
        # The ledger inode stays stable: all writers and readers lock the same file.
        mode = "r+" if args.command == "record" else "r"
        with (args.run / "decisions.tsv").open(mode, newline="") as stream:
            fcntl.flock(
                stream, fcntl.LOCK_EX if args.command == "record" else fcntl.LOCK_SH
            )
            content = stream.read()
            if not content.endswith("\n"):
                raise ValueError(
                    "unterminated ledger; inspect interrupted history before appending"
                )
            rows = list(csv.reader(io.StringIO(content), delimiter="\t"))
            validate(rows, args.run)
            if args.command == "record":
                row = [dt.datetime.now(dt.UTC).isoformat()]
                row.extend(cell(getattr(args, field)) for field in HEADER[1:5])
                row.extend([json.dumps(args.evidence), args.result])
                validate([HEADER, row], args.run)
                # Serialize before writing so validation failures never append half a row.
                buffer = io.StringIO(newline="")
                csv.writer(buffer, delimiter="\t").writerow(row)
                stream.seek(0, io.SEEK_END)
                stream.write(buffer.getvalue())
            else:
                print(
                    f"{len(rows) - 1} decision(s); evidence paths resolve; claim truth not checked"
                )
        return 0
    except (OSError, ValueError, TypeError) as error:
        print(f"evidence: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
