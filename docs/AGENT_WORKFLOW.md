# Agent evidence, pickup and corrections

Shared by Codex and Claude Code. Domain skills and AGENTS.md govern builds,
worktrees, security evidence and bench authorization. Keep task records local
and separate from tracked instructions and verification tooling.

## Local task record

For a long review or multi-phase task, create an `agent-workflow/<task>` directory
beneath the repository's gitignored scratch directory. Save the substantial
report there and link it from chat. Keep brief instructions in tracked files,
private operational details and logs in scratch. A trivial edit needs no trail.

Set `RUN` to that repo-relative task path. From the selected worktree, initialize
the new directory:

```sh
uv run --script scripts/agent-workflow/evidence.py init "$RUN"
```

The helper creates `decisions.tsv` and `checkpoint.md` and refuses to overwrite
an existing directory. On pickup use the existing directory. Fill the checkpoint
with the actual state before the first record; unknown fields stay explicitly
unknown. A pause preserves edits on disk without automatically committing them.
A new session uses a new
actor identifier; two independent tasks use separate directories. Coordinate
checkpoint edits with the task owner; the helper only locks ledger appends.

The TSV columns are timestamp, actor, phase, decision, why, evidence and result.
Results are `PASS`, `FAIL`, `UNVERIFIED`, `BLOCKED`, `INFO`. Evidence is a JSON list
of file paths, relative to the task directory or absolute for local-only records.
Log checkpoints and decisions, not every tool call. Correct mistakes by appending
a superseding row rather than rewriting history.

After saving actual command output to `host-tests.txt` in that directory:

```sh
uv run --script scripts/agent-workflow/evidence.py record "$RUN" \
  --actor session-1 --phase host-check --decision 'targeted host checks passed' \
  --why 'verify the changed parser' --evidence host-tests.txt --result PASS
uv run --script scripts/agent-workflow/evidence.py check "$RUN" --require-checkpoint
```

`PASS` and `FAIL` require an existing evidence file for the new row. Recording
checks old rows' structure without requiring their files still to exist: a lost
evidence file must not prevent the row that records its loss. `check` verifies
all evidence paths and still fails on missing old evidence, even after that loss
has been documented. Preserve old rows; a recovery entry does not restore proof.

A default `check` warns when checkpoint fields are absent or blank, including a
fresh init template. Use `--require-checkpoint` before handing off or pausing to
make those gaps fail. Fill each named template field inline or in the following
paragraph; explicit unknowns are valid content. This checks presence, not truth,
and a structurally complete checkpoint can still contain unsupported claims.
Existing handoffs may omit parenthetical hints, shorten the authorization field
to `Authorization already given`, and use `Pending work, blockers, first permitted
next action` for the final field.

The helper refuses malformed history and empty decision fields. It normalizes
multiline cells, neutralizes spreadsheet formula prefixes and serializes concurrent appends.
It does not execute commands, establish artifact provenance, prove claim truth,
make the file tamper-proof or recover a partially written row after a crash.
An interrupted/malformed ledger needs inspection and a separate recovery record;
do not silently repair history. Keep evidence files for as long as the trail.

## Pickup and verification

Read checkpoint and decisions, then inspect relevant git state and existing
evidence. Distinguish inherited claims from independently observed results.
Match evidence to source revision/dirty state, composition/image variant and
artifact identity; use a hash when recording a built artifact. Recorded exit zero
proves only the named build. A missing result is unknown; mtime proves no success.
Recheck what has changed, not every completed task from scratch. For a correction
to identity validation, enumerate the claim's required fields and reject a
fixture with each field independently missing or mismatched; the positive control
must match all of them. Include source revision and dirty state, variant/composition,
artifact hash and producer result, plus board/slot identity for target claims.

Use the existing verification surfaces, rather than generating another harness:

| Surface | Doctor / identity | Drive and evidence | Limits |
|---|---|---|---|
| Host logic | Correct worktree, changed inputs and exact command | Targeted `make test SUITE=...`; preserve output and exit status | Host success is not runtime proof; obey explicit no-test/no-command constraints |
| Metadata / image | Existing run metadata and recorded result; relevant source and composition | `prebuild-gate`, progressively targeted tasks, then image only when authorized/needed | Coordinate build ownership; use the launcher for long builds; no rebuild just to refresh an unchanged claim |
| Running target | Authorized access, board identity, image/slot, SELinux state and console owner | Existing target checks; OTA workflow for operator-invoked updates | One board per type; serial is single-user; no implicit login, reboot, flash or signing permission |
| Correction | Actual incident and existing rule/check | Bad and good cases, differential run where applicable | Fixtures do not establish recurrence; unavailable real/target evidence stays unverified |

For a target check, record the action and resulting observable state, including
side effects or unchanged state on rejection. Preserve evidence during cleanup.
Stop/release only resources the task owns, at a safe boundary. Extend existing
target checks or OTA steps for missing behavior; do not weaken a failing journey.

## General workflow plugins

Superpowers can supply general planning, debugging and testing. Repo-specific
rules still govern: `yocto-worktree` seeding precedes any build in a worktree;
generic setup or sandbox fallback does not authorize build pollution in place.
Use an existing evidence directory as the shared durable record, linking any
plugin ledger rather than copying its history. Before a plugin deletes its own
workspace, preserve referenced evidence in the task directory. A fresh check
means evidence relevant to the current claim, not a compulsory full rebuild.

## Behavioral checks for these skills

Use `scripts/agent-workflow/scenarios.md` for an independent Codex or Claude Code
evaluation in isolated scratch. Give the agent the raw scenario and applicable
skills without the scoring criteria. Evaluate produced files and actual actions,
not promises. Record model identity if available, inputs, output paths, failures
and limitations. This is a host-only test: no builds or live board operations.
