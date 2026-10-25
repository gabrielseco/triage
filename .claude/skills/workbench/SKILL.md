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
2. `workbench goal new <name>`, fill in the goal, open it for the user with `workbench open --goal --editor <name>` (`--print` gives
   the path), `goal approve` only when the user says go
3. `workbench run` (background), then `status` / `log`
4. `workbench review`, look at the verifier screenshots with `Read`; `open --editor cursor` once a worktree exists;
   then `workbench judge` (a read-only second opinion on each criterion, `judge_model` in the config; it never runs on its own,
   so run it before `accept`; its words are a note, not a pass)
   Two strikes, then the human (see the Workbench skill): the verifier cannot press `Open`, `Fix in iTerm` or `Explain` (a browser,
   another app, money; `Merge`, `Approve`, `Close` and the merge methods are pressable on the mock build), so a criterion about what
   those buttons open goes to a person's check in the `/verify` build without a second turn, and the PR says it was checked by hand
5. `send-back` if wrong; `accept`; `ship --yes --watch` (in the background: it only follows CI); then open the PR and confirm the screenshots are in it. If a visible change
   has none, run `workbench ship --screenshots` and say so if it fails (CLAUDE.md requires them for app changes)
6. `workbench pr-review --pr <n>` as soon as the PR is open, in parallel with the CI watch (do not wait for it), then post the result on the PR (CLAUDE.md step 5); fix findings and run again
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
- **Who commits at accept.** A Claude turn commits its own work, so `accept -m` prints `-m ignored: the work was already committed` and
  leaves the commit; a Codex turn leaves changes uncommitted, so `accept -m` sets the message. To reword a run's commit, run
  `git commit --amend -m "<message>"` in the worktree (`wb open --print`) before `ship`.
- **Allowlist.** `git rm` and `git commit --amend` are not in `[tools] allowed`, so a send-back asking for them is denied. The user
  edits the allowlist; do not edit `.workbench/config.toml` yourself.
- **Screenshots and the PR body.** `ship` attaches the verifier's screenshots with `pr-shots` but can skip it silently (PR #81 had
  none). Check the PR after `ship`. The description is written before any fix you push afterwards, so re-read it and correct stale
  lines (for example a file that was since removed).
- **`workbench open` needs a worktree**, which exists only after `run` starts and is removed by `ship`.
- **Repo rules still apply**: one PR per change, the PR template, no work data in PRs, Co-Authored-By on commits. Workbench's
  description turn writes the PR body, so check it against `.github/pull_request_template.md` and tick only Testing boxes that ran.
- After the user merges: `git pull` on `main` in the main checkout, `workbench clean --yes`, and list open PRs that need a rebase.
