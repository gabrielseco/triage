# Triage

Native macOS inbox for open PRs (SwiftUI, Swift 6, macOS 14+). Architecture: `README.md` and
`docs/HOW_IT_WORKS.md`.

## Commands

```bash
scripts/check.sh         # what CI runs: swift-format, SwiftLint, Swift 6 build, tests, TriageCore coverage gate
scripts/check.sh --fix   # auto-format first
scripts/bundle.sh        # build ~/Applications/Triage.app (needed for notifications, login item, Fix in iTerm)
```

## Workflow for every change

Do this without being asked:

1. **Worktree.** Work in a git worktree under `.claude/worktrees/` (gitignored), branched from `origin/main`, never in the main checkout.
2. **One PR per fix or feature.** Don't bundle unrelated changes.
3. **Check before pushing.** `scripts/check.sh --fix` must pass. Add Swift Testing tests in `TriageCoreTests` for `TriageCore` changes.
4. **Open the PR** with `.github/pull_request_template.md` (Summary, Why, collapsed What changed, Screenshots,
   Related Resources, Testing). Tick only the Testing boxes you actually ran.
5. **Run `/pr-review` on the PR** and post the result on the PR itself: inline comments per finding, or a
   short "no findings" comment. Fix the findings on the branch, push, and run `/pr-review` again.
6. **Merge only when the user asks**, and then only with CI green and no blocking findings, using a merge commit
   (`gh pr merge --merge`). After merging, say what other open PRs now need a rebase.
7. **After merging, update the main checkout.** Run `git pull` on `main` in the main checkout (not a worktree). The
   `post-merge` hook (`.githooks/`, enabled with `git config core.hooksPath .githooks`) rebuilds and restarts
   `~/Applications/Triage.app` when the app changed. Report the notification or `~/Library/Logs/Triage/rebuild.log`.

## Conventions

- Logic goes in `TriageCore` (pure, tested). The `Triage` app target is SwiftUI, persistence and OS integration, and has no tests.
- Blocking work (processes, AppleScript) goes through `TriageCore/Subprocess`, never on the main actor.
- The user never works with fork PRs, so skip fork-only edge cases.
