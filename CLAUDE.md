# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Project orientation, build commands, repo layout, conventions, and task routing live in the agent-agnostic file:

@AGENTS.md

The rest of this file is Claude-Code-specific tooling that does not apply to other agents.

## Domain skills available

Repo-local skills in `.claude/skills/` — invoke when the task fits:

- `devtool-workflow` — iterating on recipe source (U-Boot, kernel, app) via `devtool` instead of hand-editing patches: `--no-overrides`, patch export destinations, mandatory contamination verification, the U-Boot savedefconfig flow
- `yocto-worktree` — isolated worktrees for subagent/parallel builds: `kas/local.yml` seeding, shared-cache verification, branch rename-before-PR, locked-worktree cleanup
- `prebuild-gate` — run `make preflight` before any image build: maps changed paths to the cheapest check (policy source check, fragment gate, boot-script tests, do_patch, refpolicy compile, kernel configure, parse)
- `ota-bench-test` — operator-invoked only: OTA-only bench test of a new bundle (baseline, local install, recovery, streaming, tampered-bundle rejection) with a results log
- `pr-ready` — operator-invoked only: finished branch to open PR (on-target gate, `make test` + `make preflight`, diff and commit hygiene, independent review, terse PR body with a Learn/Guard/Review/Score Workflow section)

Three repo-local subagents in `.claude/agents/`:

- `selinux-policy-reviewer` — read-only review of `iotgw.te/.if/.fc` and the `/data` file-context files against the pinned refpolicy source; run it before compiling a policy change
- `build-watcher` — watches one `agent-build.py` run and reports the outcome, or the first causal error, in five lines
- `yocto-rules-reviewer` — read-only review of a recipe/patch/kas diff against `.claude/rules/*.md`; reports only violations, each with file:line, the rule and a fix

BitBake failure triage lives in `.claude/rules/yocto-patterns.md`.

## Subagents & parallel work

Delegate build-running or build-polluting tasks to subagents with `isolation: worktree`, and follow the `yocto-worktree` skill for seeding, coordination, and cleanup. Recipe/patch conventions live in `.claude/rules/recipe-conventions.md` (auto-loaded as a rule; also route subagents there explicitly).

Before starting build-running/build-polluting work or a substantial multi-file change yourself (not just when spawning a subagent), run `git status` first. If unrelated uncommitted changes from a different thread are already sitting in the tree, don't silently add to them — flag it and ask whether the new work should go in its own worktree instead. Skip this for minimal/single-file changes; bundle those per the normal PR-scope convention (`AGENTS.md` §Conventions).

## Commit trailers

The rule is `AGENTS.md` §"AI attribution": no `Assisted-by:` trailer, and
**no `Co-Authored-By:` for an AI tool** — not in commits, not in PR bodies.
This overrides the harness default, which emits a `Co-Authored-By:` line;
drop it. The `commit-msg` hook refuses it.

## Serial console + target diagnostics MCPs

Two MCP servers are wired for on-target work:

- `mcp-serial-rs` — direct UART access (`serial_list_ports`, `serial_open` on `/dev/ttyACM0`, `serial_exec`, `serial_read_until`). Prefer it for U-Boot/boot-flow debugging; close the port (`serial_close`) before the operator starts `tio`, they can't share the device.
- `mcp-netdiag-rs` — host-side network/system diagnostics (ping, routes, neighbors, sockets, dmesg, service status) for reaching and triaging the target.

The operator may still capture UART via `tio --log --log-directory $PWD/tio-session-logs /dev/ttyACM0` and share the log path. When grepping those logs, note that the file can contain high-bit / extended-ASCII control bytes that make vanilla `grep` skip lines it considers "binary". Use `grep -a` or `strings <log> | grep …` so U-Boot/firmware output isn't silently filtered out.
