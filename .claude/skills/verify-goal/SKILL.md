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
independent agent. The author must not supply the verdict or conclusions. Use the model/delegation rules
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
