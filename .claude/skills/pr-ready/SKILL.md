---
name: pr-ready
description: "Take a finished branch to an open PR: on-target validation gate, make test and make preflight, diff and commit-message hygiene, an independent review (yocto-rules-reviewer plus a different-model reviewer), then a terse PR body with a Workflow section. Operator-invoked only."
argument-hint: "[branch]"
disable-model-invocation: true
---

# PR ready

Run the steps in order and stop at the first one that fails. Report what each
step showed. The rules live in AGENTS.md ("Conventions", "Git hooks", "AI
attribution", "Validating behaviour changes") and CLAUDE.md
("Commit trailers"); this skill only orders them.

1. **On-target gate.** If the change affects runtime behaviour on the board
   (boot, OTA, kernel, SELinux policy, services, accelerators), it needs
   on-target validation, failure cases included, before a PR (AGENTS.md
   "Validating behaviour changes": the board is the oracle). If that has not
   been done, stop and say what remains to be run. Docs, host tooling and
   parse-only changes skip this.

2. **State.** `git status` is clean, the branch is rebased on `origin/main`
   (`git fetch` first), and its name follows `<type>-<scope>-<subject>`. A
   worktree branch is renamed before the PR (`yocto-worktree` skill).
   `make hooks` has been run in this clone, or the commit-msg checks below
   never ran.

3. **Gates.** Run `make help` if a target is unclear.
   - `make test` (every suite): keep the pass/fail counts.
   - `make preflight`: it diffs from the merge base with `origin/main`, so the
     branch's commits are included. A plan with 0 changed paths means the
     base is wrong, not that the change is clean. With a bitbake-tier check
     selected, run `PREFLIGHT_ARGS=--bitbake make preflight` only when no other
     build holds the build directory (`prebuild-gate` skill).

4. **Hygiene** over `git diff origin/main...HEAD` and
   `git log origin/main..HEAD`:
   - Public-repo discipline (AGENTS.md "Conventions"): only repo-relative
     paths, no absolute user paths, no gitignored or operator-local paths,
     no device IPs or lab topology, no internal planning notes, no other
     project's name. Check the diff, the commit messages and the PR body.
   - Every commit: Conventional Commit subject, body length scaled to the
     change, no `Assisted-by:` and no AI `Co-Authored-By:` (AGENTS.md
     "AI attribution"). The commit-msg hook enforces all but the
     `Assisted-by:` rule; check that one by eye, and re-check commits made
     with `--no-verify`.
   - Behaviour changes: the commit body says what was run and what it showed,
     or says "unverified".
   - Shipped patches and recipes: `.claude/rules/recipe-conventions.md`.

5. **Independent review.** Spawn the `yocto-rules-reviewer` agent on the
   branch range for recipe, patch, kas and Yocto-syntax rules, and the
   `selinux-policy-reviewer` agent when the policy module changed. Add a
   general review on a model different from the one that wrote the change.
   Give the reviewers the range, not your conclusions. Fix what they confirm
   as new commits, and re-run step 3 if anything changed. Record the verdict
   for the PR.

6. **PR.** Ask the operator before pushing. Body, terse: what changed and why
   in a few lines, how it was validated (commands and counts), and a
   **Workflow** section. No commit list, no AI `Co-Authored-By:`, and keep
   internal gaps, parked work and known issues out of the public text.

   The Workflow section makes the agent-driven process visible, one line each
   (write "none" rather than omitting a line):
   - **Learn:** the mistake, finding or decision this change comes from.
   - **Guard:** the deterministic check added or changed, and the proof it
     rejects the bad case (fails on the old code) and accepts a good one.
   - **Review:** reviewer model(s), rounds, and the verdict.
   - **Score:** what was measured against a baseline (differential run,
     before/after counts), or "not scored".

Merging is a separate step under the operator's control; this skill ends at
an open PR.
