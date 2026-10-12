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

## Permission policy

Before a request becomes a prompt, `PermissionPolicy` (`TriageCore`) decides whether it can run without
asking. The CLI has already applied the repository's own `.claude/settings*.json` rules, so only requests
those rules leave open reach the policy.

**Presets** are set per project (the shield button in the sidebar or thread header) and can be overridden
when a thread is created. New projects start on **Read-only auto**.

| Preset | Runs without asking |
| --- | --- |
| Ask | Nothing, apart from stored rules |
| Read-only auto | `Read`, `Grep`, `Glob`; `ls`, `cat`, `rg`, `find` (without `-exec`/`-delete`), `git status/diff/log/show…`, `gh pr/issue/run view/list…` |
| Workflow auto | The above, the commands in the shell code blocks of the worktree's `AGENTS.md`, `swift build/test`, and local `git add/commit/fetch/switch/merge/rebase` |

**Rules** are what **Always allow** stores: `Bash(swift test:*)` for a command prefix, or the tool name
(`Edit`). A Bash rule is never a bare `Bash`; an interpreter needs its script (`python3 scripts/x.py`), and
`git -c …` or `python3 -c …` can't be remembered. Rules apply under every preset, scoped to the thread or the
project. **In this project and its repository settings** also adds the rule to the project checkout's
`.claude/settings.local.json` (`permissions.allow`), keeping existing content and key order. A file that isn't
the expected JSON is left unchanged and the error is shown; the rule still applies in Triage. With CLI
2.1.296 the rule also took effect in a thread's linked worktree: the CLI did not ask for a command that rule
covers. Rules can be removed from the same sheet; that doesn't edit `settings.local.json`, which the CLI
also reads, so remove the entry there as well to revoke it completely.

**Guardrails** always ask, whatever the preset or a stored rule. They are written from what a program can
do rather than from a list of bad spellings:

- Programs that run other programs or can't be reasoned about never run unattended: shells and shell
  keywords, wrappers (`env`, `xargs`, `time`, `timeout`, `nice`, `command`), `sudo`, `curl`, `ssh`, `rm`,
  `sed`, `awk`, `cd`, `tee`, `open`, `npx`, and the run/exec subcommands of `uv`, `npm`, `pnpm`, `yarn`.
- Options are matched together with their unique abbreviations and clusters (`--har` is `--hard`, `-fu`
  is `-f -u`). `git` asks for force and delete variants, `reset --hard`, `clean`, `rm`, `config` writes,
  `submodule`, `bisect`, `rebase -i`, and anything that runs a program (`--exec`, `--upload-pack`, `-c`);
  `gh` asks for `api`, `alias`, `extension`, merges, deletions and `auth` other than `status`. Force
  refspecs and `--force` on `fetch`/`pull`, and `git checkout <path>`, ask. Options that follow symlinks
  (`find -L`, `grep -R`, `rg --follow`, `ls -L`) or write (`sort -o`, `tree -o`) ask.
- A path outside the thread's worktree prompts, including `..`, `~user`, a symlink pointing out, and a
  `Glob`/`glob` pattern that names files outside it. An unquoted shell glob (`cat *`) prompts, since it
  expands to entries the policy can't see; a quoted pattern (`find -name '*.swift'`) is fine.
- Commands are split on `&&`, `||`, `;`, `|` and newlines and every part must be allowed. Substitution
  (`$()`, backticks, `$VAR`), brace expansion, subshells, background jobs, here-documents, redirects other
  than `2>&1`/`/dev/null`, comments and assignment prefixes are not interpreted: the command prompts.
- **Always allow** only stores a rule for a vetted program (a subcommand tool such as `git` or `swift`, an
  interpreter with its script, a script path in the worktree, or a plain inspection tool such as `ls`
  or `rg`). Anything else can be allowed once. A stored rule covers the verb shown (`gh pr comment`, not
  `gh pr`) and is checked against the same guardrails when it matches.
- Commands that publish or act on GitHub (`git push`, `gh pr create`, `gh pr comment`) are never taken
  from `AGENTS.md` for Workflow auto; allow them once or with Always allow.

Auto-approved calls appear in the thread as `Auto-allowed: Bash \`git status\` (Read-only auto)`.

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
