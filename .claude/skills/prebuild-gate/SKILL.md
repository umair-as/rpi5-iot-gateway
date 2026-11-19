---
name: prebuild-gate
description: "Run the cheapest checks that exercise the current changes before starting an image build: SELinux policy source checks, kernel fragment gate, boot-script tests, recipe do_patch, refpolicy compile, kernel configure, or a parse. Use before any `agent-build.py start` or `make dev|prod|bundle-*`, and after editing policy, kernel fragments, recipes or boot scripts."
argument-hint: "[--bitbake] [--base REF] [--paths P ...]"
---

# Pre-build gate

An image build takes hours. Most defects that reach one would have failed a
targeted check in seconds or minutes: an undeclared policy type, a fragment
that drops a symbol, a patch that no longer applies. `make preflight` maps
the changed paths to those checks. This skill decides when to run it and how
to read the result.

## Run

1. **Host tier, always, no coordination needed:**
   ```bash
   make preflight PREFLIGHT_ARGS=--plan     # what would run, and what is not covered
   make preflight                           # run the host tier
   ```
   This needs no BitBake and does not touch `build/`. The boot-script suite
   takes a few minutes; the others take seconds.

2. **BitBake tier, only after coordinating.** It runs targeted tasks
   (`refpolicy-mcs -c compile`, `virtual/kernel -c configure`,
   `<recipes> -c patch`, or `bitbake -p`) in the shared build directory:
   ```bash
   . scripts/env.sh && make preflight PREFLIGHT_ARGS=--bitbake
   ```
   Before running it, confirm that no other agent or operator owns the build
   directory. If another session is building in this checkout, ask the
   operator first. The script also refuses (exit 3) while `build/bitbake.lock`
   exists or an `agent-build.py` run holds `build/.agent-build.lock`. Treat
   that as "wait", **never** as "remove the lock".

   A targeted task replaces `parse` (BitBake parses everything first anyway).
   The kernel configure runs with the default (dev) kas composition only.
   Prod tier fragments need a separate configure: `make bitbake-task IMAGE=prod BB_TASK="virtual/kernel -c configure"`.

## Read the result

- **Exit 0:** the selected checks passed. That is necessary, not sufficient
  (AGENTS.md §"Validating behaviour changes").
- **Exit 1:** the failing check is named on the last line. Fix it before the
  image build. For a policy failure, the `selinux-policy-reviewer` agent
  explains it against the pinned refpolicy.
- **"no fast check for N path(s)":** systemd units, config files, and
  `files/` content of recipes without a test. Only the image build, or the
  board, exercises them. Say so when reporting, rather than implying they
  were checked.

## Policy changes

When `recipes-security/refpolicy/**` changed, also run the
`selinux-policy-reviewer` agent before the bitbake tier. The mechanical
check catches undeclared types; the reviewer checks interface semantics,
neverallows and file-context aliasing, which no compiler run proves.

## Extending

When a new host test suite is added, give it a `make test-*` target and a
mapping rule in `scripts/preflight/preflight.py` (`CHECKS` and `classify`).
Add a case for it to `scripts/preflight/tests/test_preflight.py`.
