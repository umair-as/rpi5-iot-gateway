---
name: agent-evidence
description: "Keep evidence and a durable handoff for multi-phase repo work, session pickup or an explicit pause. Use for long reviews and unattended work; skip bookkeeping for trivial edits."
---

# Evidence and continuity

Read `docs/AGENT_WORKFLOW.md` for the shared format and helper commands.
This skill works for Codex and Claude Code; it grants no build or board access.

For multi-phase work, keep an `agent-workflow/<task>` directory beneath the
repository's ignored scratch directory.
Record consequential decisions and evidence as they happen. Reuse an existing
task's trail on pickup, with a new actor/session identifier; do not duplicate it
in a platform-specific ledger. Supersede mistaken rows with new rows.

On pickup, read the checkpoint, recent decisions and relevant git state.
Separate inherited reports from observed evidence. Check that recorded source,
image variant and artifact identity cover the current claim. An old successful
build does not prove changed sources; a newest artifact is not a successful build.
Inspect existing records before proposing work; do not rebuild merely to refresh
evidence. No result means unknown, not success. State the first permitted next action.

On an explicit pause, finish the current safe atomic step and update checkpoint.md.
List scoped dirty files, verified outcomes, remaining uncertainty, running build
owners/paths and board/serial state. Preserve unrelated edits and running builds.
Do not auto-commit, push, terminate processes or clean worktrees to make a pause
look tidy. Close only a serial session you own when safe, recording any handoff.

Save long reviews and findings in scratch and link them from the chat. Report
which verification axes passed and which remain unverified. No mandatory extra
review agent or transcript access is needed. Explicit user output constraints win.
