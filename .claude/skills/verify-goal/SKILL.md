---
name: verify-goal
description: Independently check a Triage implementation against its approved goal and write verdict.json tied to the goal and exact staged tree before delivery. Use after implementation or any subsequent fix.
---

# Verify goal

The input is the task slug and implementation worktree. Read `goal.md` and `goal.json` first.
Use [the artifact contract](../../../docs/artifacts/README.md) for the verdict shape.
This checks whether the request is fulfilled. The existing [verify](../verify/SKILL.md) supplies bundled-app
evidence; [pr-review](../pr-review/SKILL.md) still reviews engineering quality after PR creation.

## Prepare the review

Finish formatting, lint and required checks, then stage all delivery changes. Do not stage local goals,
verdicts, logs or screenshots. Unstaged and nonignored untracked changes block verification.

```bash
python3 scripts/task-goal.py snapshot <slug>
```

This records `verification-input.json` with the approved goal hashes, branch, comparison base and staged
Git tree. Pass its absolute path, the goal directory, this skill's absolute path and the worktree to an
independent agent. Also pass the green CI run ID for this commit if there is one, and the tree of the
previous verdict if this is a re-verification. The author must not supply the verdict or conclusions. Use the model/delegation rules
from `AGENTS.md`; do not inherit implementation claims as evidence.

If an independent agent is unavailable, report verification as unavailable. Do not self-certify PASS.

## Independent verifier instructions

Do not change implementation files, stage files, alter goals, or mark the task done. You may run local
tests and write your result to `.claude/tasks/<slug>/verifier-result.json`. Before running a command named
as proof, inspect it for external side effects; goal verification does not authorize deployment, merging,
posting or spending credits. Use existing evidence for such actions, or mark them unverified.

Read the goal and snapshot yourself, inspect the working tree and the staged diff against `baseCommit`,
and check each approved criterion. Commands:

```bash
git status --short
git diff <baseCommit> --cached
```

For each criterion, cite observed proof: test result, command result, file and line, or inspected screenshot.
Do not trust ticked checkboxes or the author's summary. An unmet or unverified criterion has `pass: false`.
Also check unmet parts of the request, unexpected changes, scope exclusions, and weakened criteria.
Missing evidence or unresolved concerns require an overall `fail`.

### Stopping rule

Verification answers "is each approved criterion met?", not "is this code flawless?". It is bounded:

- **Fail only on a reproduced violation of a criterion's literal text**, or on missing, unexpected or weakened
  work. Show the input and the observed result. A hunch, a theoretical bypass you could not reproduce, or an
  edge case the criterion does not name is not a failure.
- **`concerns` holds only unresolved violations.** Everything else (accepted risks, hardening ideas,
  polish) goes in your chat report to the caller, who puts it in the PR description or a follow-up. If the
  same observation was already reported and accepted in an earlier round, do not re-raise it.
- **Probe each criterion once, proportionally.** For an adversarial criterion (for example "guardrails
  always prompt"), try the named patterns and a short list of the obvious variants, then stop. Do not search
  open-endedly for new bypass classes.
- **On a re-verification, start from the delta.** Read what changed since the last PASS or FAIL
  (`git diff <previous tree> <staged tree>`). Re-check the criteria that delta can affect, and confirm
  the others by spot check. A delta that touches only tests or docs cannot break a production criterion
  unless a test was removed or weakened, so check exactly that.

### Test evidence

Do not rebuild and re-run the whole suite by default. Prefer, in order:

1. **A green CI run for this exact commit.** The caller may pass an Actions run ID. Confirm with
   `gh run view <id> --json conclusion,headSha` that it succeeded and that `headSha` is the staged commit
   (or that the tree is identical), then cite the run as the proof for "checks pass" criteria.
2. **The author's recorded `scripts/check.sh` result** for the staged tree, when no PR or run exists yet.
3. **A targeted local run** (`swift test --filter <suite>`) only for a criterion whose proof names a test
   you need to see fail or pass, or when neither of the above is available.

Run the full `scripts/check.sh` yourself only when the criterion is "check.sh passes" and no green run or
recorded result covers the staged tree.

Write a result in the v1 verdict format, with every criterion in the goal's order and exact text:

```json
{
  "schemaVersion": 1,
  "taskID": "task-slug",
  "verdict": "pass",
  "criteria": [{"text": "Exact approved criterion", "pass": true, "evidence": ["Observed proof"]}],
  "missing": [],
  "unexpected": [],
  "concerns": [],
  "provenance": {}
}
```

Copy the entire `verification-input.json` object into `provenance` before examining the implementation.
Never refresh it to hide changes during verification. Record missing/extra work and concerns as strings
in those arrays. A passing criterion requires nonempty evidence. Overall PASS requires all criteria met
and all three arrays empty. The independent agent reports its verdict and result path to the caller.

## Publish and deliver

The caller publishes the independent result with:

```bash
python3 scripts/task-goal.py record <slug> --input .claude/tasks/<slug>/verifier-result.json
python3 scripts/task-goal.py check <slug>
```

The helper checks criterion coverage, evidence and provenance and atomically writes `verdict.json`.
It does not generate the verdict. On FAIL, fix the work, stage it, take a new snapshot and run a new
independent review. Keep unresolved failures visible; do not stamp a PASS result onto newer code.

Commit after PASS, then check again before push and PR creation. A commit with the same tree keeps the
verdict valid; changed code, changed goals, a different branch, unstaged edits or extra files require
verification again. The Git pre-push hook enforces delivery when hooks are enabled; Claude also checks
PR creation with its repo hook. Other clients must run the check explicitly before creating a PR.
