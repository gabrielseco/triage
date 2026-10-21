---
name: workbench
description: Drive a Triage change through the Workbench CLI, from goal to PR review (doctor, goal, run, review, accept, ship, pr-review, clean). Use ONLY when the user says to use Workbench ("use workbench", "run it with workbench", "workbench goal"). Ordinary changes follow CLAUDE.md.
allowed-tools: Bash(workbench:*), Bash(wb:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr comment:*), Read, Edit, Write
---

# Workbench in Triage

The lifecycle is defined once, in the Workbench repo: `~/rogal/workbench/.claude/skills/workbench/SKILL.md`. **Read it before the first
command**, then follow it step by step. Do not work from `workbench --help`: that is how doctor and the PR review got skipped.

This file adds only what is specific to Triage.

## The steps, in short (each is a gate)

1. `workbench doctor`
2. `workbench goal new <name>`, fill in the goal, show it, `goal approve` only when the user says go
3. `workbench run` (background), then `status` / `log`
4. `workbench review`, look at the verifier screenshots with `Read`; `open --editor cursor` once a worktree exists
5. `send-back` if wrong; `accept`; `ship --yes`
6. `workbench pr-review --pr <n>` after the PR is open, then post the result on the PR (CLAUDE.md step 5); fix findings and run again
7. Stop. Merge only when the user asks (CLAUDE.md step 6)

## Triage specifics

- **Binary.** Use a current build: `swift build -c release` in `~/rogal/workbench`, then `.build/release/workbench`. A stale build
  rejects newer config keys (`judge_model`, `[verifier] enabled`, `[run]`). Run commands from `~/rogal/triage`.
- **Config** is `.workbench/config.toml` (gitignored, local). Its check is `scripts/check.sh`, the verifier uses
  `.claude/skills/verify/SKILL.md` and `scripts/verify-app.sh` on mock data, and review stages are `pr-review` and `design`.
  The `design` stage applies to `Sources/Triage/**` and `Resources/**`; for a visible change run it with
  `workbench review-stage design`.
- **Untracked files get committed.** The run's `git add -A` and `workbench accept` both commit untracked files from the worktree
  (`.vscode/launch.json` ended up in PR #81 twice). Before `accept`, run `workbench review` and read the file list; if something
  unrelated is there, `git rm --cached` it in the worktree and amend. Put "do not commit untracked files" in the goal's out of scope.
- **Allowlist.** `git rm` and `git commit --amend` are not in `[tools] allowed`, so a send-back asking for them is denied. The user
  edits the allowlist; do not edit `.workbench/config.toml` yourself.
- **`workbench open` needs a worktree**, which exists only after `run` starts and is removed by `ship`.
- **Repo rules still apply**: one PR per change, the PR template, no work data in PRs, Co-Authored-By on commits. Workbench's
  description turn writes the PR body, so check it against `.github/pull_request_template.md` and tick only Testing boxes that ran.
- After the user merges: `git pull` on `main` in the main checkout, `workbench clean --yes`, and list open PRs that need a rebase.
