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
  verdict.json
  shots.json
  shots/*.png
  reviews/<source>.json
  events.jsonl
```

Task outputs are gitignored. `goal.md` remains human-readable Markdown and is not parsed in v1.
The verifier, review skills and hooks will adopt their respective JSON outputs in subsequent PRs.
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
| `verdict.json` | `verdict` (`pass` or `fail`), `criteria`: array of `{text, pass, evidence: [String]}` | None |
| `shots.json` | `screenshots`: array of `{path, caption}` | Each screenshot: `appearance` (`light` or `dark`), `criterion` |
| `reviews/<source>.json` | `source`, `findings`: array of `{severity, message}` | Each finding: `file`, `line` |
| `events.jsonl` | Per line: `id` (UUID), `timestamp` (ISO 8601), `kind`, `payload` (string-to-string object) | None |

Review severity is `blocking`, `warning`, or `suggestion`. An empty findings array means the review
ran and found nothing; an absent review file means it has not run. Review file/line fields are evidence
labels, not instructions to open arbitrary paths.

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

Next: adopt verdict/review/event producers, then validate the installed CLI control protocol before
building the streaming engine.
