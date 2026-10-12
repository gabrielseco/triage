# Task artifacts, version 1

Workbench phase 0 gives CLI work a machine-readable output without parsing agent prose.
This PR defines readers and a screenshot producer; thread execution and UI come later.

## Identity and layout

A task ID is a lowercase kebab slug, such as `workbench-artifacts`. It is local to a project and
must stay unchanged across follow-ups. A future thread stores its task ID separately from its CLI
session UUID. Multi-repo work stores artifacts in the primary repo's worktree.

```text
.claude/tasks/<taskID>/
  goal.md
  goal.json
  verification-input.json
  verdict.json
  shots.json
  shots/*.png
  reviews/<source>.json
  events.jsonl
```

Task outputs are gitignored. `goal.md` remains human-readable Markdown and is not parsed in v1.
`goal.json` supplies the machine-readable goal; the helper renders both and rejects mismatches.
Independent goal verification produces verdicts, and completed PR/design reviews produce review files.
Event producers are subsequent work.
The [examples](examples) are illustrative documents, not claims that verification has run.
The example screenshot manifest references an image a producer would create; images are not fixtures.

## Common envelope

Every JSON document and every JSONL record includes `schemaVersion: 1` and `taskID`.
Consumers require both, reject unsupported versions and task mismatches, and tolerate unknown fields.
Missing files mean the step has not produced an artifact. Invalid documents are errors, not empty results.
Publish JSON files with a temporary file and atomic rename so readers never see partially written JSON.
Readers run away from the main actor; their file reads are synchronous.

## Documents

| File | Required fields after the envelope | Optional fields |
| --- | --- | --- |
| `goal.json` | `branch`, `baseCommit`, `request`, `criteria`: array of `{text, proof}`, `outOfScope`: string array, `status` | `approvedGoalSHA256`, `changesAfterApproval`: string array |
| `verdict.json` | `verdict` (`pass` or `fail`), `criteria`: array of `{text, pass, evidence: [String]}` | None |
| `shots.json` | `screenshots`: array of `{path, caption}` | Each screenshot: `appearance` (`light` or `dark`), `criterion` |
| `reviews/<source>.json` | `source`, `findings`: array of `{severity, message}` | `status`, `provenance`; each finding: `file`, `line`, `evidence` |
| `events.jsonl` | Per line: `id` (UUID), `timestamp` (ISO 8601), `kind`, `payload` (string-to-string object) | None |

## Goal verification and delivery

Use the shared [goal skill](../../.claude/skills/goal/SKILL.md) before substantive work and
[verify-goal skill](../../.claude/skills/verify-goal/SKILL.md) before committing. Codex discovers the same
files through relative `.agents/skills` symlinks. Approval already given for the task remains valid;
record it explicitly rather than asking again. A helper cannot decide whether approval was given.

`scripts/task-goal.py` creates and approves goals, snapshots staged changes, and records independently
produced verdicts. `revise` archives prior goal/verification files under `history/<UUID>`, logs the reason,
and revokes approval; revised criteria require authorized approval and a new independent review.

`verification-input.json` contains `schemaVersion`, `taskID`, `branch`, `baseCommit`, `tree`,
`goalSHA256`, and `goalManifestSHA256`. The independent verifier copies it into the verdict's
`provenance` field. Additional verdict fields `missing`, `unexpected`, and `concerns` are string arrays.
These are optional to generic v1 artifact readers, which still read core verdict fields. Delivery checks
require matching provenance, exact criterion coverage, nonempty evidence for every passing criterion,
all criteria passed, and no unresolved issues. The verifier evaluates evidence; the helper validates its
shape and freshness, not the truth of arbitrary text or the identity of its author.

The gate checks the staged Git tree and both goal hashes, so committing the verified tree remains valid.
Unstaged edits, nonignored untracked files, changed staged code, goal changes, or a branch change block
delivery. Stage all delivery files after checks and before taking the snapshot. Without an explicit slug,
`check` requires exactly one local task matching the current branch; ambiguity fails closed.
Task outputs belong to the implementation worktree, not a sibling checkout.

Enable Git hooks with `git config core.hooksPath .githooks` (the repo already uses this for post-merge).
The pre-push hook checks branch deliveries from their own worktrees and refuses a pushed tree that
differs from the staged tree. Tag pushes and branch deletions are outside this code-delivery gate.
Claude's Bash hook checks ordinary `gh pr create` commands, including literal `cd` paths and environment
prefixes. It is a workflow guardrail, not a shell interpreter or security boundary: aliases, scripts and
dynamically constructed commands must explicitly run `python3 scripts/task-goal.py check` too.
Codex and other clients share the Git hook and instruction file and must run the same check before
PR creation. Neither hook grants approval, runs an agent or manufactures a verdict.

Review severity is `blocking`, `warning`, or `suggestion`. An empty findings array means the review
ran and found nothing; an absent review file means it has not run. Review file/line fields are evidence
labels, not instructions to open arbitrary paths.

## Review producer

The shared PR and design review skills publish `.claude/tasks/<taskID>/reviews/<source>.json`
when a task is present. Standalone reviews without a task retain their existing GitHub workflow.
Both skills continue to post findings or a no-findings comment on the PR. Local artifact publication
does not establish that posting succeeded; report any posting error separately.

Before reviewing, stage the implementation and capture the review's code and goal context:

```bash
python3 scripts/task-review.py snapshot <taskID> pr-review --base <baseRefOid> --head <headRefOid>
```

Use source `design-review` for design checks. Load the PR's exact commit IDs with
`gh pr view <n> --json baseRefOid,headRefOid`; before a PR exists, use its intended base and omit `--head`.
Run in the task's implementation worktree. Snapshot requires an approved goal, no unstaged edits or
nonignored untracked files, and a staged tree matching `--head` when supplied. A reviewer must not
stage unrelated user edits to satisfy this requirement.

The snapshot is written to `review-inputs/<source>.json`, outside the completed-review directory.
It contains the v1 envelope, `source`, `branch`, `baseCommit`, `tree`, both goal hashes and optional
`headCommit`. Copy that entire object as `provenance` into the review result before inspecting the code.
Do not resnapshot at the end to hide intervening changes.

Write the reviewer's result in the ignored task directory, for example `review-results/pr-review.json`:

```json
{
  "schemaVersion": 1,
  "taskID": "task-slug",
  "source": "pr-review",
  "status": "complete",
  "provenance": {},
  "findings": [
    {
      "severity": "blocking",
      "message": "Concrete input and failure observed by the reviewer",
      "file": "Sources/TriageCore/Example.swift",
      "line": 12,
      "evidence": ["Observed command result, screenshot path or design rule"]
    }
  ]
}
```

Replace `provenance` with the complete captured object. `file`, `line` and `evidence` are optional;
file paths must be repo-relative without traversal, and a positive integer line requires a file.
Evidence is an array of nonempty strings. Design grades map Blocking → `blocking`, Polish → `warning`,
Nit → `suggestion`. Retain the visual problem, cited rule and inspected screenshot in the evidence.
Register inspected design PNGs with `task-shot.py` before cleanup and use their task-relative paths.

A completed clean review writes `findings: []`. A skipped design review or an inspection lacking required
evidence does not publish a completed artifact. The helper does not perform the review or infer findings.

```bash
python3 scripts/task-review.py record <taskID> pr-review \
  --input .claude/tasks/<taskID>/review-results/pr-review.json
```

Publication validates the v1 findings, completion status and captured provenance against the current
tree, goal and branch. Invalid, incomplete or stale input leaves any previous completed file intact.
Valid input atomically replaces the latest result for that source and preserves additional JSON metadata.
Review the same task/source sequentially. Older results can remain after code changes, so consumers
must compare provenance to the current goal/tree before presenting them as current.

TriageCore reads optional completion/provenance and finding evidence, while accepting earlier v1 fixtures
without those additions. Producers require them. Consumers must not infer a current clean review from
a file's existence alone or treat a missing artifact as a review that passed.

Screenshot paths are task-relative, beneath `shots/`; absolute paths, traversal, backslashes and
percent-encoded paths are rejected. Consumers must also resolve symlinks and check containment before
opening images; the decoder validates the path text, not the filesystem. Captions describe what was
inspected. Use distinct filenames for light/dark, before/after and different states.

Events are append-only, one complete JSON object plus newline per record. A single writer must own the
log, or writers must share a lock. Consumers can deduplicate by event UUID. Blank lines are ignored;
an incomplete or malformed record fails the read and can be retried after the writer finishes.
`kind` is extensible: initial conventions are `pr.created`, `pr.merged`, and `ci.completed`.
Their payloads carry `repo` and `url`; `ci.completed` also carries `status`. Producers should not
put tokens, credentials, or raw environment dumps in artifacts.

## Screenshot producer

After capturing and inspecting a PNG with `/verify`:

```bash
python3 scripts/task-shot.py workbench-artifacts /path/to/inbox-light.png \
  "Inbox after refresh" --appearance light --criterion "Inbox remains usable"
```

The helper defaults to `.claude/tasks` relative to the current directory; use `--task-root` to target
another primary worktree. It copies the PNG and publishes `shots.json`, preserving other captures.
Re-registering the same filename updates its entry. The helper locks manifest updates, rejects a
different task/version in an existing manifest, and preserves unknown manifest fields.
Run captures for the same task sequentially so a reader sees a consistent image and caption.
Python 3 is already used by this repository's coverage tooling. The helper uses macOS `sips` to verify
that image bytes can be decoded before publishing them, and preserves the original capture bytes.

## Completion criteria

- v1 fixtures decode; missing, malformed, future-version and mismatched-task artifacts are distinguished.
- Screenshot traversal is rejected before a future UI resolves a path.
- The screenshot producer publishes a manifest accepted by TriageCore and preserves prior entries.
- `/verify` instructions publish inspected task screenshots without depending on the Workbench UI.

Next: adopt event producers, then validate the installed CLI control protocol before
building the streaming engine.
