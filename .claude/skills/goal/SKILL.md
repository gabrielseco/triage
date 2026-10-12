---
name: goal
description: Record a Triage task's request, acceptance criteria, proof and scope before implementation, including approval for later independent verification.
---

# Goal

Use the implementation worktree. One task has one stable lowercase kebab slug; keep it for follow-ups.
The shared helper creates `.claude/tasks/<slug>/goal.md` for humans and `goal.json` for the delivery gate.
Both are local and gitignored. Do not create a second goal for another agent working on the same task.

Write an input JSON file in an ignored task/scratch directory with:

```json
{
  "request": "The user's request, verbatim",
  "criteria": [
    {"text": "Observable acceptance criterion", "proof": "How to demonstrate it"}
  ],
  "outOfScope": ["Work this task does not include"]
}
```

Derive criteria from the authorized request, retaining constraints and any follow-up corrections.
Include outcomes that tests alone cannot establish, such as the on-screen state when appropriate.
For a small fix, a single criterion is enough. Questions require no goal.

Run from the worktree:

```bash
python3 scripts/task-goal.py init <slug> --input <input.json> --base origin/main
```

Read the generated goal. If the user has already approved the work and these criteria only spell out
that scope, record that approval without asking again. If they introduce an unresolved product decision,
present the goal and wait for that decision before recording approval or starting dependent work.

```bash
python3 scripts/task-goal.py approve <slug>
```

The helper records approval; it cannot determine whether the user gave it. Never treat running the
command as authorization. After approval, do not silently weaken or remove criteria. For a user-requested scope change, write the
revised input and run `python3 scripts/task-goal.py revise <slug> --input <input.json> --reason "User requested …"`.
This archives the previous files, logs the change and returns the same goal to draft. Record approval again
only when the revised scope is authorized. Reuse the same goal for implementation follow-ups that keep its
criteria. Any change to either goal file invalidates existing verification.

Before delivery, invoke [verify-goal](../verify-goal/SKILL.md). Enable the repo's existing Git hooks with
`git config core.hooksPath .githooks` if not already enabled. This adds no user approval on its own.
