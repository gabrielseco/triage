---
name: pr-review
description: Thoroughly review a GitHub pull request on this repo as a senior macOS/Swift engineer — Swift 6 strict concurrency and actor isolation, TriageCore/app layering, blocking Process calls off the main actor, secret handling (Keychain, 1Password, key helpers), shell/AppleScript injection in the handoff path, sticky item-id semantics in the Classifier, UserDefaults persistence, and bundle-only APIs (notifications, SMAppService) — not just generic Swift best practices. Use when the user asks to "review this PR", "review PR #N", pastes a GitHub PR URL and asks for feedback, or asks "what do you think of this PR". For reviewing local staged/uncommitted changes before a commit, defer to the general /code-review skill instead.
allowed-tools: Bash(git:*), Bash(gh:*), Bash(scripts/check.sh:*), Bash(swift:*), Bash(swiftlint:*), Read, Grep, Glob
---

# PR Review

Diff-scoped review of a GitHub PR on Triage, done the way a senior macOS engineer would: checked
against `README.md`, `docs/HOW_IT_WORKS.md`, the lint/format config and this project's feedback
memory — not a generic Swift pass. Scale depth to the diff: a one-file fix gets a quick pass, a new
feature (new rule in `Classifier`, new Settings pane, new external process or API) gets the full
checklist.

## Step 1 — Load context

- Resolve the PR number from the user's message, or from the current branch if unspecified:
  `gh pr view --json number,title,body,headRefName,baseRefName,statusCheckRollup`
- `gh pr diff <number>` for the diff.
- For each changed file, read it in full (`git show origin/<branch>:<path>` or `Read` on a checkout of
  the branch) — hunks alone hide the isolation context (is the enclosing type `@MainActor`? is this
  inside a `Task.detached`?) and the persistence context (is the property `didSet`-saved?).
- `gh pr checks <number>` for CI. CI is `scripts/check.sh` (swift-format → SwiftLint strict → Swift 6
  build with warnings-as-errors → tests). If it failed, report why first. If CI hasn't run and the
  branch is checked out locally, run `scripts/check.sh` yourself — don't review what the compiler
  would already reject.

## Step 2 — Read the rules

- `README.md` (Development section) and `docs/HOW_IT_WORKS.md` for the architecture.
- `.swiftlint.yml`, `Tests/.swiftlint.yml`, `.swift-format` — so you don't re-flag what tooling owns
  (layout, line length, force unwraps outside tests, `print`). Only raise a lint-owned issue if the PR
  suppresses it (`// swiftlint:disable`, a relaxed rule in the config) without a reason.
- Skim project memory (`/Users/gabriel/.claude/projects/-Users-gabriel-rogal-triage/memory/`) for
  `feedback` entries relevant to what changed, so the review doesn't re-raise something already decided.

## Step 3 — Analyze the diff

Check against this repo's actual invariants:

**Layering (`TriageCore` vs `Triage`)**

- `TriageCore` is the pure, testable library: no `AppKit`/`SwiftUI`/`UserNotifications`/
  `ServiceManagement` imports, no `UserDefaults`, no UI state. It's also what moves server-side in the
  planned Phoenix backend, so logic that belongs to "GitHub snapshot → items → prompt" goes here, not in
  the app target. Flag classification, prompt assembly, or parsing logic added to `AppStore` or a view.
- The `Triage` target owns UI, persistence and OS integration (`AppDelegate`, `Notifier`,
  `LoginItem`/`SMAppService`, `ITerm`). Views stay thin: they call `store` methods inside
  `Task { await store.… }`; they don't call `GitHubClient`/`AnthropicClient` directly.
- New `AppStore` behavior of any size goes in an `AppStore+<Feature>.swift` extension, matching
  `+AI`, `+Digest`, `+Handoff`.

**Swift 6 concurrency & isolation**

- The compiler catches data races, so look for what it *doesn't* catch:
  - **Blocking the main actor.** `Process.waitUntilExit()`, `readDataToEndOfFile()`, `Thread.sleep`,
    synchronous file I/O over large files, or `NSAppleScript.executeAndReturnError` called from
    `@MainActor` code (`AppStore`, views, `AppDelegate`) freezes the UI. The house pattern is
    `OnePassword.run`: wrap the process in `Task.detached { … }.value`. Note `GitHubAuth.resolveToken()`
    and `Handoff.git` are synchronous today — a PR that calls them from new main-actor paths, or in a
    loop, should move them off-main rather than add more callers.
  - **Pipe deadlocks.** A `Process` whose stdout/stderr can exceed the pipe buffer (~64 KB) and is read
    only *after* `waitUntilExit()` will hang. Read before waiting (as `OnePassword.run` does), and don't
    leave a `Pipe()` on stderr that's never drained if the tool can be chatty.
  - **Escape hatches.** Flag new `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`,
    or `MainActor.assumeIsolated` without a comment proving why it's safe.
  - **Unstructured tasks.** A bare `Task { }` inherits the actor; `Task.detached` doesn't. Check the
    choice is intentional. Long-lived loops (like `startAutoRefresh`) must be guarded against starting
    twice. Actions triggered by a button should tolerate double clicks (see `refresh()`'s
    `isRefreshing` guard).
  - **Reentrancy.** After any `await` inside `AppStore`, state may have changed: `selection`, `items`,
    or `repos` can differ from before the suspension. Flag code that reads state before an `await` and
    writes derived state after it without re-checking.
  - `nonisolated` delegate callbacks (`UNUserNotificationCenterDelegate`) must hop back with
    `Task { @MainActor in … }` before touching the store — never touch store state directly.
- `TriageCore` public types crossing into the app should be `Sendable` value types (as in `Models.swift`).

**Classifier & item identity** (`Sources/TriageCore/Classifier.swift`)

- Item ids encode "what would make this worth looking at again": `\(pr.id)|<kind>|<headSha or latest
  comment id>`. Dismiss/snooze are keyed by id and pruned in `refresh()` when the id disappears. So:
  - An id that's **too stable** (missing the sha / latest-comment component) makes a dismissal hide
    new failures forever.
  - An id that's **too volatile** (includes a timestamp, count, or ordering-dependent value) makes
    dismissed items pop back every 2-minute refresh and breaks the digest baseline.
- One item per (PR, kind) — a new rule must collapse many raw events into one item, not one per comment
  or job. Noise bots are matched via `normalizedLogin`; new bot handling should go through that set.
- Severity changes affect `needsYouCount`, sort order and the digest. Call them out explicitly.
- Every new rule or id change needs a `ClassifierTests` case, including the "dismissed item stays
  dismissed until something new happens" behavior.

**Digest** (`Digest.swift`, `AppStore+Digest.swift`)

- Time logic takes `now`/`Calendar` as inputs so `DigestTests` can pin them; flag new `Date()` calls
  inside `TriageCore` logic. Check the weekday, midnight and DST boundaries, plus the "missed slot fires on
  next refresh, once" rule.

**Persistence** (`AppStore`)

- Settings are `didSet`-persisted to `UserDefaults` via `save`/`load` (JSON). Renaming a key, or
  changing a persisted type's `Codable` shape, silently resets users' settings, because `load` returns
  `nil` on a decode failure. Flag it unless there's a migration or the loss is acceptable and stated.
- Unbounded persisted collections (`dismissed`, `snoozed`, digest ids) must be pruned the way
  `refresh()` prunes against live ids.
- Bundle id is `dev.rogal.triage`; `scripts/bundle.sh` migrates from the old `Triage` domain. New
  keys work in both `swift run` and bundled builds.

**Secrets**

- The Anthropic key can come from four sources: key reference (`op://` or helper script via
  `KeyReference`), `ANTHROPIC_API_KEY`, Keychain, or none. Only the *reference* is persisted, never the
  key. The key is cached in memory (`cachedOnePasswordKey`) and cleared when the reference changes.
  Flag anything that writes a key or GitHub token to `UserDefaults`, a file, a log, an error message,
  `actionStatus`, or a prompt file.
- Keychain: `kSecClassGenericPassword` with the existing service. Check `SecItem*` status codes on new
  calls instead of ignoring them silently when the user-facing result depends on success.
- Error surfaces (`GitHubError.http` truncates the body to 300 chars) must not echo request headers.

**Handoff, shell & AppleScript** (`Handoff.swift`, `AppStore+Handoff.swift`, `ITerm`)

- Anything interpolated into the generated zsh script goes through `Handoff.shellQuote`. Branch
  names, repo names and paths are attacker-controlled (fork PRs choose their branch name). Flag any raw
  `\(…)` of PR-derived data in the script body. `prNumber` is an `Int`, so it's fine.
- `harnessCommand` is a user-owned template; only `{prompt_file}` is substituted, as `"$PROMPT_FILE"`.
- AppleScript sources escape `\` and `"` (see `ITerm.open`). New AppleScript needs the same escaping,
  and the Automation-permission error message.
- Prompt and script files contain PR content (diffs, logs). They go in `~/Library/Caches/dev.rogal.triage/handoffs/`,
  not `/tmp` or another shared path. The file name comes from owner, repo, number and kind, so check new name parts can't contain `/` or `..`.
- `HandoffScriptIntegrationTests` runs the real script. Worktree-flow changes (fork PRs, existing
  worktree, branch already checked out) should extend it.

**GitHub & Anthropic clients**

- GraphQL: new fields added to `prQuery` need matching `Decodable` structs (nesting up to 3 is
  allowed by lint for this). Check pagination limits (`first: N`): a truncated connection silently
  under-reports checks, threads or comments. Check `null`s from GitHub are optional in the Decodable.
- Rate limits: one refresh = one query per repo every 120 s. Flag per-PR or per-item extra requests in
  the refresh loop.
- Anthropic: model ids default to `AnthropicClient.defaultModel`. Keep the refusal fallback. Response
  parsing should tolerate unexpected content blocks.

**macOS app specifics**

- Notifications, the login item (`SMAppService`) and Apple Events only work in the bundled app.
  `swift run` has no bundle id and `UNUserNotificationCenter` crashes. New uses must be guarded like
  `AppDelegate`'s bundle-id check.
- New privacy-sensitive capability (Apple Events to another app, file access outside the sandbox-less
  defaults, camera and so on) needs an `NS…UsageDescription` added to the `Info.plist` heredoc in
  `scripts/bundle.sh`.
- The app targets macOS 14 (`Package.swift`, `LSMinimumSystemVersion`). Flag APIs newer than macOS 14 that
  lack `if #available`.
- SwiftUI: `@Observable` store, read via `@Environment`/passed reference. No `ObservableObject`/
  `@Published` in new code. Views shouldn't do expensive derivation in `body`. `activeItems` is
  recomputed on every access, so flag new hot-path callers that call it repeatedly in a loop. Check keyboard
  shortcuts and menu commands don't collide with existing ones in `TriageApp.swift`.
- Window/activation: `NSApp.activate(ignoringOtherApps:)` is deprecated on 14+; it's tolerated where
  it exists, but new code should not add more.

**Tests**

- `TriageCore` changes come with `TriageCoreTests` using Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest, as in the
  existing files. The app target has no tests, which is another reason logic belongs in `TriageCore`.
- Tests must not hit the network, the real Keychain, `op`, or the real clock. Integration tests that
  spawn processes (`HandoffScriptIntegrationTests`) use temp dirs and clean up.

**Standard correctness sweep**

- Force-unwraps/`try!` sneaking past lint via `// swiftlint:disable`, optional chains that silently
  swallow a failure the user should see (write it to `errors`/`actionStatus`), off-by-one in
  `prefix`/`suffix` on log tails, `String(decoding:)` on huge `Data`, retain cycles in stored closures
  (`openMainWindow`) capturing `self` strongly from a view or delegate.

**Comment quality**

- Comments are opt-in: flag ones that restate the code, or doc comments that describe mechanism rather
  than behavior. The codebase's style is a one-line `///` that explains *why*. Never flag a missing comment.

Focus on changed code. Only flag a pre-existing issue if the diff makes it worse or newly relevant.
When uncertain about intent, phrase it as a question.

## Step 4 — Specialized passes (only when the diff warrants it)

For a large diff, run these as parallel `fork` subagents:

- **Concurrency**: every new `await`, `Task`, `Process`, and `nonisolated`, with the isolation traced.
- **Security**: secrets, shell/AppleScript interpolation, prompt-file handling, token scopes.
- **UI/UX**: SwiftUI views, macOS HIG conformance (menu bar, Settings scene, keyboard navigation,
  VoiceOver labels on icon-only buttons, dark mode), empty/loading/error states.
- **Test quality**: are the ids, the time boundaries and the failure paths actually asserted?

## Step 5 — Report findings

Use the `ReportFindings` tool with verified findings ranked most-severe first (empty array if the diff
is clean; don't manufacture issues). Each finding needs a concrete failure scenario (inputs/state →
wrong output, hang, crash, or leaked secret), not just a description of the deviation.

## Step 6 — Post as PR comments, only with explicit approval

Ask: "Want me to post these as inline comments on the PR? Include nitpicks?"

By default, post blocking and medium-severity findings only; nitpicks are opt-in.

If yes:

- `gh pr review <number> --comment --body "..."` for a summary, or `gh api` for inline comments
  anchored to file:line.
- Format with [conventional comments](https://conventionalcomments.org/): `issue (blocking):` for
  correctness, concurrency, security or data-loss risks, `suggestion:` otherwise, `nitpick:` for
  style, `praise:` when something is done well.
- Suffix every comment with `[by Claude]`.
