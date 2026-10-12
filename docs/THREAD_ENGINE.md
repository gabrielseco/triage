# Threads

Open **Threads** from the inbox toolbar or Window menu. Add a local Git repository, choose
**New thread**, and describe the work. The model defaults to the project's CLI configuration;
the creation sheet also offers a per-thread override.

Every thread receives its own Git branch, worktree and Claude session UUID. The CLI runs in that
worktree, loads normal project instructions/settings/skills, and is asked to follow `AGENTS.md`.
Workbench does not replace the project's verification or review workflow. Artifact cards and
multi-repository execution are later phases.

## Runs and recovery

`ThreadSupervisor` owns at most two CLI processes. Work waits in a queue when both are busy.
Completed processes keep stdin open for follow-ups. When queued work needs a slot, an idle process
is closed; a later follow-up resumes its saved session in the same worktree.

The Threads window shows user/assistant messages, tool activity, streaming text and pending tool
permissions. **Allow once** replies with the original tool input; **Deny** rejects that invocation.
Project permission rules remain effective. Unsupported host control requests receive an error response.
The host never enables permission bypass. **Raw output** shows a bounded tail for diagnostics.

**Stop** cancels queued work or interrupts a live turn and closes its process, with a bounded termination
fallback. Closing a window keeps runs alive. Quitting stops processes and saves metadata. After restart,
unfinished threads appear interrupted; send a message with **Resume** to continue. Work is not
automatically repeated after a crash. Initialization, malformed output and nonzero exits produce errors.

Projects and thread metadata live in `~/Library/Application Support/Triage/threads/catalog.json`.
Session transcripts belong to the Claude CLI; raw host logs live in `~/Library/Logs/Triage/threads/`.
Files are private to the local user. A corrupt catalog is reported and preserved rather than silently
reset. Verification can isolate the new metadata/logs with `--workbench-data-directory <directory>`;
this does not change inbox settings or the project's CLI instructions.

Worktrees use `.claude/worktrees/` when that path is ignored by the project. Otherwise they live in
an adjacent `<repository>-worktrees/` directory. The base is the first available remote default,
`origin/main`, `origin/master`, or local `HEAD`. Uncommitted checkout changes are not copied. Worktrees
are retained for follow-ups and project lifecycle recording.

## Validated CLI protocol

The installed Claude Code **2.1.296** was exercised on 2026-10-12 in temporary Git repositories with
tiny authenticated Haiku turns. Observed behavior:

- Two turns through one open stdin preserved context.
- A fresh `--resume` process recalled the saved marker.
- An explicit `--session-id` matched returned session IDs, and normal `CLAUDE.md` instructions loaded.
- Host approval executed harmless `pwd`; denial rejected it.
- A control interrupt during a pending denied tool turn was acknowledged and produced an error result.

The host launches `claude -p` with stream-json input/output, verbose partial messages, replayed user
messages, `--permission-prompts host` and `--permission-prompt-tool stdio`. It sends an `initialize`
control request and waits for the correlated acknowledgement before sending the first user message.
Production keeps ordinary project settings, hooks and MCP servers; isolated probe flags are not used.

The wire format is newline-delimited JSON. A `result` completes a turn, not the process. The host validates
the primary session ID, ignores unknown event types, folds full assistant blocks without duplicating
their partial text, and cancels stale permission prompts. Input writes are serialized; both output
pipes drain concurrently off the main actor. Frames are bounded to 8 MiB, displayed partial text to
32,000 characters, raw output to 256,000 characters and saved display history to 200 messages.

Protocol references are Anthropic's official SDK
[query implementation](https://github.com/anthropics/claude-agent-sdk-python/blob/b6e9d12fe1cc98dde988ab7b7713c1feeee50c6c/src/claude_agent_sdk/_internal/query.py)
and [CLI transport](https://github.com/anthropics/claude-agent-sdk-python/blob/b6e9d12fe1cc98dde988ab7b7713c1feeee50c6c/src/claude_agent_sdk/_internal/transport/subprocess_cli.py).
Sanitized live probe evidence is task-local under `.claude/tasks/thread-engine/protocol/`.

## Validation

Swift Testing exercises real local subprocesses for incremental output, stdin, concurrent pipe pressure,
termination and startup errors. Scripted CLI fixtures exercise permissions, follow-ups, queueing,
resume, malformed output and session mismatch. Disposable Git repositories check worktree isolation,
instruction symlinks and paths containing spaces or shell syntax. Storage tests cover recovery,
corruption, file permissions and bounded diagnostic reads. Live app verification complements these
tests; fixtures do not claim a real model call occurred.
