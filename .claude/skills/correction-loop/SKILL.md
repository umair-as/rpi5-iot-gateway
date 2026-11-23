---
name: correction-loop
description: "Turn a demonstrated recurring agent mistake into a scoped deterministic guard, or record why it still needs judgment. Use after an operator correction or evidence of a repeated failure."
---

# Correct the mechanism

Read the affected repo rule and existing check before proposing another one.
Record the concrete failure and its evidence under the task's scratch directory.
Separate demonstrated incidents from suspected recurrence; do not invent history.

Try the highest useful level: remove the invalid choice through architecture,
encode the invariant in types, add a deterministic check with an actionable error,
then a behavior test. Use prose for the judgment the mechanism cannot express.
Keep useful operational explanations even after adding a guard.

Choose the smallest correction within the authorized task. An unrelated mistake
gets a recorded follow-up, not an automatic refactor or separate PR. Never treat
a proposed control as installed enforcement or permission to merge.

Prove the check rejects the actual bad case and accepts a legitimate case. For
an identity-dependent claim, list the required fields and test one mismatch or
missing-value case per field while holding the others valid: source revision,
dirty input state, image variant/composition, artifact hash and producer result;
include board/slot identity when the claim depends on a target. The positive
control must match every required field. A successful build from another source
is a negative case even when its artifact hash is valid. Mark fields outside the
claim as not applicable with a reason; untested required fields stay unverified.

For matching/classification, compare old and new against real inputs in both
directions and explain the whole delta (AGENTS.md). Synthetic fixtures are useful
tests, not historical evidence. If real evidence or authorization is unavailable,
save a draft and say exactly what remains unverified.

Use the repo's existing Make/test/preflight entry points for an implemented guard.
Host tests come first; no image build or board run merely to test this workflow.
For an unsupported success claim, inspect the producer's recorded result and
source/artifact identity; neither mtime nor another agent's confidence is proof.

Use agent-evidence's format for the correction and verification record. Do not
edit plugin caches, suppress security findings, invent provenance or expand
permissions as part of a correction. Skill changes and behavioral evaluations
need evidence of their own, not only a frontmatter check.
