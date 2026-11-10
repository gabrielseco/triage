# Explain PR through Workbench

Explain PR no longer builds a prompt. Triage runs the existing `workbench explain-pr` command, wraps the Markdown it
produces in front matter, keeps it as a note and opens it in Obsidian. Triage makes no AI call of its own, and posts
nothing: the note is for you.

## The Workbench contract Triage relies on

The source of truth is Workbench's `docs/plan/explain-pr.md`; this is what Triage depends on. Nothing changes on the
Workbench side.

```
workbench explain-pr --pr <n>
```

- **Where it runs:** the repository's local clone (any folder in it), as the working directory. Triage finds the clone
  as it did for the iTerm hand-off (remembered, else `<root>/<repo name>` whose origin matches, else a folder picker).
  The PR must be open, on a branch of origin (not a fork), and `gh` must be installed.
- **No `--out`.** Workbench always keeps the file at `.workbench/explains/pr-<n>-<head7>.md`; Triage reads it back, so
  that it, not Workbench, decides where the note goes.
- **stdout:** progress lines, then on success **the last line is the absolute path of the file**, alone. Triage reads
  that line and nothing else.
- **stderr, on failure:** one line, `workbench: <kind>: <message>`. Triage shows `<kind>: <message>`.
- **Exit codes:** 0 written (or reused for an unmoved head), 1 failed, 2 usage, 6 refused. Any non-zero is an error
  shown to the user.
- **The file:** Markdown body only, no front matter, ending in one newline. The head it explains is in its name
  (`<head7>`); when that differs from the head Triage saw, the note is for the head in the name.
- **Reuse:** an unmoved head is not explained again (exit 0, same file), so running again on the same head is cheap.
  A moved head names a different file and is explained afresh.

The command takes minutes (an agent runs on a checkout), so it runs through `TriageCore/Subprocess`, off the main actor.

## The note

`<vault>/<path>-<pr>-<head7>.md`, where

- `<vault>` is the **Obsidian vault folder** setting (Settings → Explain PR);
- `<path>` is the repo's `owner/name` with the slash as a dash (`acme-web`; a GitLab group's slashes too);
- `<pr>` is the number and `<head7>` the first seven characters of the head explained.

```markdown
---
pr: acme/web#412
head: 0123456789abcdef0123456789abcdef01234567
generated: 2026-11-09T19:30:00Z
---

# (Workbench's Markdown)
```

Running again for the same head replaces the note; a new head makes a new note, and older ones stay.

With no vault set, the note goes to `~/Library/Application Support/dev.rogal.triage/explains/` and is revealed in Finder.

## Opening in Obsidian

`obsidian://open?vault=<vault folder name>&file=<note name without .md>`, each part percent-encoded like JavaScript's
`encodeURIComponent` (a space is `%20`).

Checked against the installed app (Obsidian 1.15.0, `/Applications/Obsidian.app`): its Info.plist registers the
`obsidian` scheme, and the app builds this very form for its own "Copy Obsidian URL"
(`"obsidian://open?vault=" + encodeURIComponent(vaultName) + "&file=" + encodeURIComponent(path)`); its `open` handler
resolves `file` as a link path, so the extension is optional. The vault's name is the folder's name, which is what
Obsidian calls a vault by default. Triage does not use the `path=` form, which is not what this version generates.
If nothing handles the scheme (Obsidian is not installed), the note is revealed in Finder instead.

## What the item shows

| State | Under the Explain PR button |
|---|---|
| Running | a spinner and "Explaining…"; the button is disabled. The run's progress and errors show in the same place |
| Done | "Explained · <age>", a link that reopens the note |
| Head moved | "Explained · <age> — older commit, run again" in orange; the link still opens the old note, Explain PR runs again |
| Failed | "Couldn't explain #n: <Workbench's message>" |

A finished run, and a failed one, also send a notification (when the bundled app can). The record (head, note path,
time) is kept per PR in the app's settings.

## Mock mode

Workbench is never run in mock mode. A scenario's `explains` list starts PRs out as `running`, `done` (for the current
head) or `stale` (for another), so the three states can be seen and verified: `Mocks/default.json` has one of each.
Opening a note does nothing in mock mode.

## Out of scope

Thread-level explanations; posting an explanation anywhere; anything on the Workbench side.

## Review threads: explain, fix, report

Each review thread (bot or human) of a GitHub PR with a local clone shows **Explain**. Triage runs
`workbench explain-thread --pr <n> --thread <id>` in the clone; Workbench prints one JSON object,
`{"reasoning": "...", "proposed_fix": "..."}`. Triage shows both and keeps them by thread id and head SHA; once the PR's
head moves the explanation is marked as written for an older commit.

With an explanation on screen the thread offers **Fix** and **False positive**:

- **Fix** runs only when pressed: `workbench fix-thread --pr <n> --thread <id>` applies and pushes the fix and prints
  `{"commit": "<sha>"}`, then `workbench reply-thread --pr <n> --thread <id> --body "Fixed in <short sha>"` posts the reply.
  The reply text is shown in the thread's status before it is posted. After a refresh the thread reads the reply and
  shows "Fix reported" (see `ThreadStates`).
- **False positive** hides the thread's actions on this Mac only; nothing is sent to the forge. **Undo** brings them back.
- **Resolve** is a separate button that resolves the thread on the forge (GitHub's `resolveReviewThread`). Fixing or
  dismissing never resolves a thread.

The `Mocks/default.json` scenario starts with one explained thread; mock mode runs a fake Workbench
(`MockWorld.threadWorkbench()`) whose fix lands as a commit and a reply in the mock's own PR.
