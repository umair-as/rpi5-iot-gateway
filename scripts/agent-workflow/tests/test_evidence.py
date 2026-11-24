"""Exercise the public CLI, including rejected claims and concurrent writers."""

import csv
import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "evidence.py"


def cli(*args: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        text=True,
        capture_output=True,
        check=False,
    )


@pytest.fixture
def run(tmp_path: Path) -> Path:
    path = tmp_path / "run"
    assert cli("init", path).returncode == 0
    return path


def record_args(run: Path, result: str = "INFO") -> list[str]:
    return [
        "record",
        str(run),
        "--actor",
        "session-1",
        "--phase",
        "review",
        "--decision",
        "reviewed inputs",
        "--why",
        "check current scope",
        "--result",
        result,
    ]


def rows(run: Path) -> list[list[str]]:
    with (run / "decisions.tsv").open(newline="") as stream:
        return list(csv.reader(stream, delimiter="\t"))


def test_init_never_overwrites_handoff(run: Path) -> None:
    handoff = run / "checkpoint.md"
    handoff.write_text("existing session's handoff")
    assert cli("init", run).returncode == 1
    assert handoff.read_text() == "existing session's handoff"
    assert len(rows(run)) == 1


@pytest.mark.parametrize("result", ["PASS", "FAIL"])
def test_verified_outcome_requires_file_without_appending(
    run: Path, result: str
) -> None:
    before = (run / "decisions.tsv").read_bytes()
    assert cli(*record_args(run, result)).returncode == 1
    assert cli(*record_args(run, result), "--evidence", "absent.txt").returncode == 1
    assert (run / "decisions.tsv").read_bytes() == before


@pytest.mark.parametrize("result", ["PASS", "FAIL", "UNVERIFIED", "BLOCKED", "INFO"])
def test_outcomes_preserve_evidence_and_history(run: Path, result: str) -> None:
    evidence = run / "check output.txt"
    evidence.write_text("actual check output\n")
    assert cli(*record_args(run, result), "--evidence", evidence.name).returncode == 0
    prior = (run / "decisions.tsv").read_bytes()
    assert cli(*record_args(run)).returncode == 0
    assert (run / "decisions.tsv").read_bytes().startswith(prior)
    assert json.loads(rows(run)[1][-2]) == [evidence.name]
    assert cli("check", run).returncode == 0
    assert evidence.read_text() == "actual check output\n"


def test_check_detects_deleted_evidence_and_does_not_repair(run: Path) -> None:
    evidence = run / "result.txt"
    evidence.write_text("exit 0")
    assert cli(*record_args(run, "PASS"), "--evidence", str(evidence)).returncode == 0
    before = (run / "decisions.tsv").read_bytes()
    evidence.unlink()
    assert cli("check", run).returncode == 1
    assert (run / "decisions.tsv").read_bytes() == before


def test_lost_evidence_allows_followup_but_not_a_false_clean_check(run: Path) -> None:
    evidence = run / "result.txt"
    evidence.write_text("exit 0")
    assert cli(*record_args(run, "PASS"), "--evidence", evidence.name).returncode == 0
    before = (run / "decisions.tsv").read_bytes()
    evidence.unlink()
    args = record_args(run)
    args[args.index("--decision") + 1] = "evidence for the PASS row was lost"
    assert cli(*args).returncode == 0
    assert (run / "decisions.tsv").read_bytes().startswith(before)
    assert len(rows(run)) == 3
    assert cli("check", run).returncode == 1
    assert cli(*record_args(run, "PASS"), "--evidence", "absent.txt").returncode == 1
    assert len(rows(run)) == 3


def test_blank_checkpoint_warns_and_fails_readiness_check(run: Path) -> None:
    before = (run / "checkpoint.md").read_bytes()
    result = cli("check", run)
    assert result.returncode == 0
    assert "checkpoint" in result.stderr
    assert "Goal and requested milestone" in result.stderr
    assert cli("check", run, "--require-checkpoint").returncode == 1
    assert (run / "checkpoint.md").read_bytes() == before


@pytest.mark.parametrize("inline", [True, False])
def test_filled_checkpoint_passes_readiness_check(run: Path, inline: bool) -> None:
    checkpoint = run / "checkpoint.md"
    separator = ": " if inline else ":\n\n"
    checkpoint.write_text(
        checkpoint.read_text().replace(
            ":\n\n", separator + "Unknown; not observed.\n\n"
        )
    )
    result = cli("check", run, "--require-checkpoint")
    assert result.returncode == 0, result.stderr
    assert not result.stderr


def test_partial_checkpoint_reports_each_missing_field(run: Path) -> None:
    checkpoint = run / "checkpoint.md"
    checkpoint.write_text(
        "# Handoff\n\nGoal and requested milestone: review only\n\nDecision trail: decisions.tsv\n"
    )
    result = cli("check", run, "--require-checkpoint")
    assert result.returncode == 1
    assert "Worktree, branch" in result.stderr
    assert "Pending work, blockers" in result.stderr
    assert "Goal and requested milestone" not in result.stderr


def test_short_checkpoint_labels_preserve_existing_handoff_style(run: Path) -> None:
    (run / "checkpoint.md").write_text(
        """# Handoff

Goal and requested milestone: documentation review
Worktree, branch, source revision and scoped dirty files: unknown
Verified outcomes: none
Inherited claims and unverified axes: runtime unverified
Running builds: another session owns the build; details unknown
Board / slot / image identity and serial owner: unknown; no serial opened
Authorization already given: documentation only; no target access
Pending work, blockers, first permitted next action: review the saved report
Decision trail: decisions.tsv
"""
    )
    result = cli("check", run, "--require-checkpoint")
    assert result.returncode == 0, result.stderr
    assert not result.stderr


def test_missing_checkpoint_is_reported_without_creating_it(run: Path) -> None:
    checkpoint = run / "checkpoint.md"
    checkpoint.unlink()
    assert cli("check", run, "--require-checkpoint").returncode == 1
    assert "checkpoint" in cli("check", run).stderr
    assert not checkpoint.exists()


def test_missing_run_is_not_created(tmp_path: Path) -> None:
    run = tmp_path / "absent"
    assert cli(*record_args(run)).returncode == 1
    assert not run.exists()


@pytest.mark.parametrize("bad", ["wrong\theader\n", "ts\tactor\n", ""])
def test_malformed_history_is_preserved(run: Path, bad: str) -> None:
    ledger = run / "decisions.tsv"
    ledger.write_text(bad)
    assert cli(*record_args(run)).returncode == 1
    assert cli("check", run).returncode == 1
    assert ledger.read_text() == bad


def test_interrupted_row_is_not_silently_completed(run: Path) -> None:
    ledger = run / "decisions.tsv"
    with ledger.open("a") as stream:
        stream.write("2000-01-01T00:00:00+00:00\tsession")
    before = ledger.read_bytes()
    assert cli(*record_args(run)).returncode == 1
    assert ledger.read_bytes() == before


def test_complete_but_unterminated_row_is_not_concatenated(run: Path) -> None:
    assert cli(*record_args(run)).returncode == 0
    ledger = run / "decisions.tsv"
    ledger.write_bytes(ledger.read_bytes().rstrip(b"\r\n"))
    before = ledger.read_bytes()
    assert cli(*record_args(run)).returncode == 1
    assert cli("check", run).returncode == 1
    assert ledger.read_bytes() == before


def test_untrusted_text_stays_one_inert_cell(run: Path) -> None:
    args = record_args(run)
    args[args.index("--decision") + 1] = "=formula\twith\nnewlines"
    assert cli(*args).returncode == 0
    assert rows(run)[1][3] == "'=formula with newlines"
    assert len(rows(run)) == 2
    args[args.index("--why") + 1] = " \n "
    assert cli(*args).returncode == 1
    assert len(rows(run)) == 2


def test_concurrent_writers_keep_every_row(run: Path) -> None:
    jobs = []
    for number in range(12):
        args = record_args(run)
        args[args.index("--actor") + 1] = f"session-{number}"
        jobs.append(
            subprocess.Popen(
                [sys.executable, str(SCRIPT), *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        )
    for job in jobs:
        _, error = job.communicate(timeout=15)
        assert job.returncode == 0, error
    assert len(rows(run)) == 13
    assert {row[1] for row in rows(run)[1:]} == {f"session-{i}" for i in range(12)}
    assert cli("check", run).returncode == 0


def test_hash_content_under_a_field_counts_as_filled(run: Path) -> None:
    text = (run / "checkpoint.md").read_text()
    text = text.replace(
        "Goal and requested milestone:\n", "Goal and requested milestone:\n#40 merged\n"
    )
    (run / "checkpoint.md").write_text(text)
    result = cli("check", run)
    assert "Goal and requested milestone" not in result.stderr


def test_ledger_rows_end_in_lf_only(run: Path) -> None:
    assert cli(*record_args(run)).returncode == 0
    assert b"\r" not in (run / "decisions.tsv").read_bytes()
