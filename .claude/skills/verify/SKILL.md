---
name: verify
description: Run a PR's build of Triage.app and check on screen that the change does what the PR says — build the worktree into a throwaway bundle, swap it in for the installed app, drive it, screenshot the Triage window, compare against the PR's claims, then restore the installed app. Use for any PR that touches the app target (Sources/Triage, Resources) before opening or merging it, or when the user asks to "verify", "try it in the app", "check it works" or "get screenshots". Pure TriageCore changes are verified by their tests instead.
allowed-tools: Bash(scripts/bundle.sh:*), Bash(scripts/snap.sh:*), Bash(TRIAGE_APP=*), Bash(open:*), Bash(pkill:*), Bash(pgrep:*), Bash(swift scripts/ax.swift:*), Bash(sips:*), Bash(gh:*), Bash(git:*), Bash(rm:*), Read
---

# Verify

Tests cover TriageCore; nothing covers the SwiftUI app. This skill is the check for the app: run the PR's
code as a real bundle, look at it, and say whether it matches what the PR claims. Workbench runs it too, with
the tools listed in `[verifier]` of its config: see "Under Workbench".

## Under Workbench

If `WORKBENCH_PROOF_DIR` is set, Workbench started you (`workbench verifier`) on a thread's worktree, and this is the only
part of the skill that applies: Steps 2 to 5 are for a person's own checkout and real accounts, and you have no tools for
them. You have `Read` and `scripts/verify-app.sh`, nothing else. Never use `open`, `pkill` or `scripts/bundle.sh`, and never
touch `~/Applications/Triage.app`.

1. **What to show.** Read `$WORKBENCH_GOAL`: each criterion and its `proof:`. A `proof: screenshot: <name>` line names
   `<name>.png`, which you leave in `$WORKBENCH_PROOF_DIR`. Read the diff-relevant files named in the criteria with `Read`
   when you need to know what should be on screen.
2. **Start the build.** `scripts/verify-app.sh start` builds this worktree into a throwaway bundle with its own bundle id, opens
   it on mock data (`Mocks/default.json`, or `start Mocks/<file>.json` for a state the goal names) and prints
   `pid=`, `window=` and `size=`. Keep the pid: every other command needs it, and refuses any other. Read the scenario file
   first if you need to know which states it has. If the state a criterion needs is in no scenario, say so in your report;
   do not look for it in the installed app.
3. **Drive it.** `scripts/verify-app.sh list <pid>` shows what is on screen (role and label). `scripts/verify-app.sh press
   <pid> "<label>"` presses a button or selects a row (an exact label, else a prefix). Wait about two seconds after a press
   before you look: SwiftUI animates. It refuses `Approve`, `Merge`, `Squash`, `Rebase`, `Close`, `Open`, `Fix in iTerm` and
   `Explain`; a criterion about one of those buttons is checked by seeing that it is listed, not by pressing it.
4. **Capture.** In the state a criterion needs, `scripts/verify-app.sh shot <pid> <name>` writes
   `$WORKBENCH_PROOF_DIR/<name>.png`. `Read` that file and look at it: if it does not show the state, press again and take it
   again under the same name. A criterion that names several screenshots (before and after a press, a second window size)
   gets one `shot` each, in the order the goal names them.
5. **Stop it, always.** `scripts/verify-app.sh stop <pid>`, also when a step failed. It ends only that build and removes
   its settings.
6. **Report.** One line per criterion: its id, `holds` or `does not hold`, and what you saw, naming the file. Say plainly when
   the goal needed a state you could not reach or a button you may not press. Workbench shows this as a note beside the
   screenshots; it decides nothing, a person looks at the screenshots.

## Permissions

- **Screen Recording** for iTerm: needed for any screenshot. Without it `screencapture` saves only the wallpaper,
  so check that the first screenshot shows the Triage window.
- **Accessibility** for iTerm: needed to click (`scripts/ax.swift`). The script exits with "No Accessibility
  permission" if it's missing. In that case don't stop. Screenshot what shows on launch, and for each
  interaction tell the user exactly what to click, wait for "done", then screenshot.

## Step 1: What should be visible

Read the PR (`gh pr view <n> --json title,body,files` and `gh pr diff <n>`) and write a short checklist of
things you can see on screen: which view, which state, what should now look different. Include one
unchanged neighbouring view as a regression check. If nothing in the diff is visible (e.g. TriageCore only),
say so and stop.

## Mock data first

Unless the PR is about what real GitHub, GitLab or Linear data looks like, check it on mock data: the app reaches
nothing real, shows the same state on every run and has no private titles to leak into a screenshot. `scripts/mock.sh`
opens a throwaway build on `Mocks/default.json` beside the installed app (its own bundle id, settings and no
Keychain), and `scripts/verify.sh` is the same build driven by Workbench. A state the default scenario lacks is a new
file under `Mocks/` (docs/plans/MOCK.md). Steps 2 to 5 below are for changes that need the user's real accounts.

## Step 2: Build the PR into a throwaway bundle

From the PR's worktree (never the main checkout). Shell variables don't survive between Bash calls, so every
snippet below starts by setting `V` itself. Write the real scratchpad path in place of `<scratchpad>`.

```bash
V=<scratchpad>/verify/Triage.app   # never ~/Applications
TRIAGE_APP="$V" scripts/bundle.sh
```

It uses the same bundle id, so it reads the user's real settings, repos and Keychain key. Because it's
signed ad hoc, macOS may show a Keychain prompt. If a dialog appears in a screenshot, ask the user to click it.

## Step 3: Swap it in

Only one instance per bundle id can run, and `open` would just focus the installed one. Launch with `open -g` so
the app starts behind the user's windows instead of taking focus. They keep working while this skill runs:

```bash
V=<scratchpad>/verify/Triage.app
INSTALLED="$HOME/Applications/Triage.app/Contents/MacOS/Triage"
pgrep -qf "$INSTALLED" && touch "$(dirname "$V")/was-running"   # read back in Step 5
pkill -f "$INSTALLED" || true
open -g "$V"
```

Wait for the first refresh (poll `scripts/snap.sh` every few seconds until the list isn't empty/loading,
up to ~30s) instead of a fixed sleep.

## Step 4: Drive and capture

Nothing here needs the app in front, so never activate it, click its window or minimize it. `snap.sh` captures the
window even when other windows cover it, as long as it's on the current Space, and `ax.swift` presses through
Accessibility without moving the mouse.

- Screenshot: `scripts/snap.sh <scratchpad>/verify/<step>.png`, then `Read` it. For a retina capture, first run
  `sips -Z 1600 <png>` on a copy so it's cheap to read. Look at it. Don't assume the step worked.
- List what's on screen: `swift scripts/ax.swift`. Each line is a role and a label: sidebar filters and repos,
  list rows by their text, and detail buttons (`Explain & propose fix`, `Fix in iTerm`, `Copy prompt`, `Snooze`,
  `Dismiss`, `Close PR`, `Open`, `Refresh`).
- Press one: `swift scripts/ax.swift press "CI failing"`. The label is an exact match, or else a prefix. Rows get
  selected and buttons pressed. Wait ~1.5s before the screenshot, because SwiftUI animates the change.
- Without Accessibility, tell the user what to click, wait, then screenshot.
- Recording for the PR (optional, e.g. an animation): `scripts/snap.sh <scratchpad>/verify/flow.mov 10`. You can't
  watch it, so it's for the user and isn't evidence.

**Side effects: this is the user's real account.** Never click Close PR, anything that posts to GitHub, or
Explain (costs API credits) unless the PR is about that button and the user says OK. Dismiss and Snooze
only change local state. If you use them, undo them before finishing.

## Step 5: Restore, always, even if a step failed

```bash
V=<scratchpad>/verify/Triage.app
[[ "$V" == */verify/Triage.app ]] || exit 1        # an empty V would make the pkill below match the installed app
pkill -f "$V/Contents/MacOS/Triage" || true
rm -rf "$V"                                        # so a notification click can't launch the PR build later
if [[ -e "$(dirname "$V")/was-running" ]]; then
  rm "$(dirname "$V")/was-running"
  sleep 1 && open -g "$HOME/Applications/Triage.app"
fi
```

## Step 6: Report

For each checklist item give ✅/❌ and the screenshot path. Then state the verdict: matches the PR, or
what differs. Screenshots can't be uploaded to the PR with `gh`, so list the files for the user to drag into
the PR's Screenshots table. For Before shots, run Step 2 from `origin/main` (a throwaway worktree) or
capture the installed app before the swap if it matches main. Only tick the "Tried in the bundled app"
Testing box when this ran.

This checks behaviour, not looks. If the PR changes anything visible, run `/design-review` next: it reuses
Steps 2, 3 and 5 and reviews the result against `docs/DESIGN.md`.
