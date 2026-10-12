# Triage

Native macOS inbox for open PRs (SwiftUI, Swift 6, macOS 14+). Architecture: `README.md` and
`docs/HOW_IT_WORKS.md`. UI rules: `docs/DESIGN.md`.

## Commands

```bash
scripts/check.sh         # what CI runs: swift-format, SwiftLint, Swift 6 build, tests, TriageCore coverage gate
scripts/check.sh --fix   # auto-format first
scripts/bundle.sh        # build ~/Applications/Triage.app (needed for notifications, login item, Fix in iTerm)
scripts/snap.sh out.png  # screenshot the Triage window (out.mov 10 records 10s), used by /verify
```

## Workflow for every change

Do this without being asked:

1. **Worktree.** Work in a git worktree under `.claude/worktrees/` (gitignored), branched from `origin/main`, never in the main checkout.
2. **Goal and independent verification.** For substantive changes, use the shared `goal` skill to record
   the request, criteria with proof, and scope under `.claude/tasks/<slug>/`. Existing explicit task approval
   counts; ask only when the criteria introduce an unresolved decision. Never record approval that was not given.
   Before committing, stage the final changes and run `verify-goal` with an independent agent. Fix failures and
   verify again. `verdict.json` must PASS for the approved goal and staged tree. Code or goal changes invalidate
   the verdict. Questions need no goal. For a one-line fix, use a short goal; the delivery gate has no silent bypass.
3. **One PR per fix or feature.** Don't bundle unrelated changes.
4. **Check before pushing.** `scripts/check.sh --fix` must pass. Add Swift Testing tests in `TriageCoreTests` for `TriageCore` changes.
   For changes to the app target (`Sources/Triage`, `Resources`), run `/verify` too. It runs the PR build and
   screenshots it, and those screenshots go in the PR. If the change is visible (layout, styling, copy, a new
   view or state), run `/design-review` after `/verify` and fix its blocking findings before pushing. It checks
   the build against `docs/DESIGN.md` in light and dark mode and at the minimum window size.
5. **Open the PR** only after `python3 scripts/task-goal.py check <slug>` succeeds for the current branch.
   Git's pre-push hook enforces this when `.githooks` is enabled; Claude's PR-creation hook checks it too.
   Other clients must run the same check explicitly before PR creation. Write the PR with `.github/pull_request_template.md` (Summary, Why, collapsed What changed, Screenshots,
   Related Resources, Testing). Tick only the Testing boxes you actually ran.
   After creation succeeds, record `pr.created` with the lifecycle observer below.
6. **Run `/pr-review` on the PR** (and `/design-review` if the change is visible) and post the result on the PR
   itself: inline comments per finding, or a short "no findings" comment. Fix the findings on the branch, push,
   and run `/pr-review` again.
7. **Merge only when the user asks**, and then only with CI green and no blocking findings, using a merge commit
   (`gh pr merge --merge`). After merging, say what other open PRs now need a rebase.
   Record observed CI completions and the confirmed merge from the task worktree before cleanup.
8. **After merging, update the main checkout.** Run `git pull` on `main` in the main checkout (not a worktree). The
   `post-merge` hook (`.githooks/`, enabled with `git config core.hooksPath .githooks`) rebuilds and restarts
   `~/Applications/Triage.app` when the app changed. Report the notification or `~/Library/Logs/Triage/rebuild.log`.

## Conventions

- Logic goes in `TriageCore` (pure, tested). The `Triage` app target is SwiftUI, persistence and OS integration, and has no tests.
- Blocking work (processes, AppleScript) goes through `TriageCore/Subprocess`, never on the main actor.
- The user never works with fork PRs, so skip fork-only edge cases.

## Task lifecycle events

Claude and Codex use the same observer after successful GitHub actions, from the task's implementation
worktree. Keep the task worktree until its merge has been recorded, including when the user merges on
GitHub. Use the full PR head commit and the actual Actions run ID:

```bash
python3 scripts/task-event.py pr-created <slug> --pr <number> --head <headCommit>
python3 scripts/task-event.py ci-completed <slug> --pr <number> --head <headCommit> --run <runID>
python3 scripts/task-event.py pr-merged <slug> --pr <number> --head <headCommit>
```

Record each completed Actions run observed while checking CI, including failures and cancellations.
The observer reads GitHub state; it does not create a PR, run CI, merge, or authorize those actions.
Pending runs produce no completed event. A recorded successful run does not replace checking all
required CI and review findings before merging. If GitHub succeeded but local recording failed, report
that separately and retry the observer; retries preserve history without duplicate events. See
[the event producer contract](docs/artifacts/README.md#event-producer) for identity and recovery rules.

## Shared skills

Project skills live in `.claude/skills/`; `.agents/skills/` links to the same folders for Codex discovery.
Edit the shared files rather than creating separate Claude and Codex versions.

- `goal`: record the request, acceptance criteria, scope and approval.
- `verify-goal`: independently validate the approved criteria and write a revision-bound verdict.
- `verify`: run the bundled app, check behavior, capture screenshots, and restore the installed app.
- `design-review`: review visible changes against `docs/DESIGN.md`, including screenshots.
- `pr-review`: review a GitHub PR against this project's architecture and conventions.

Claude invokes goal validation as `/goal` and `/verify-goal`; Codex uses `$goal` and `$verify-goal`.
Claude invokes app checks as `/verify`, `/design-review`, and `/pr-review`; Codex uses `$verify`,
`$design-review`, and `$pr-review`. Read the corresponding `SKILL.md` before following its workflow.
When delegating work that needs a skill, provide its shared file path to the subagent.

Use the current agent's equivalent tools: shell execution for Bash, file reads/search for Read/Grep/Glob,
and image viewing for screenshot inspection. Claude-specific `allowed-tools` metadata does not grant
permissions in other agents; their runtime permissions still apply. Screen Recording and Accessibility
must be granted to the app or terminal actually running the commands.
