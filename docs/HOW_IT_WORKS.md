# Triage: how the whole thing works

A guide to the project for someone who knows TypeScript, React and Elixir but not Swift. Every Swift
concept is mapped to the closest thing you already know.

---

## 1. What problem it solves

With many open PRs across several repos, the raw event stream is too noisy to follow: CI runs,
bot comments, review threads, merge conflicts. Triage reads GitHub repos you choose and, optionally, the
GitLab merge requests assigned to you or waiting on your review. Triage turns that stream into a **short list of attention
items**, each with a reason and a next action:

```
GitHub (30 open PRs, ~150 checks, ~100 bot comments) + GitLab (your MRs)
        │  fetch every 2 min
        ▼
Classifier (plain rules, no AI)
        │  collapse + mute noise
        ▼
~13 attention items   ──►  you decide: dismiss / snooze / open / explain / fix
        │
        ├─► "Explain & propose fix" → one Claude API call
        ├─► "Copy Claude Code prompt" → paste into a local checkout to fix
        └─► 12:00 / 18:00 digest notification: "3 new since 12:00"
```

Two design rules drive everything:

1. **The unit is the attention item, not the PR.** A PR is only a container. Five failing jobs on one
   commit are one item; ten comments from one bot are one item.
2. **Deterministic first, AI on demand.** Classification is plain `if` rules, so it's free, instant and
   testable. Claude is called only when you click "Explain", once per click.

---

## 2. Using it

| What | How |
|---|---|
| Launch / rebuild | `triage` in the terminal (zsh function in `~/.zshrc`) |
| Watch a repo | Type `owner/repo` (or paste a GitHub URL) in the sidebar field → Enter |
| Stop watching | Right-click the repo in the sidebar → Stop watching |
| GitLab | Settings → GitLab → Show GitLab merge requests, then paste a `read_api` token (or keep one in the Keychain). Projects appear in the sidebar by themselves |
| Linear | Settings → Linear → Show Linear pings, then paste a personal API key with Read access. Mentions and replies in your threads appear under **Linear** in the sidebar until you answer them in Linear. Each new one sends a notification (click it to open the comment), then reminders after 1 h, 4 h and daily |
| Refresh | ⌘R, or wait. It auto-refreshes every 2 minutes, Linear every 30 seconds |
| Explain an item | Select it → **Explain & propose fix** (⌘E) |
| Open PR in browser | **Open** (⌘O) |
| Hide an item | **Dismiss** (Delete key) or **Snooze** 1h / 4h / until tomorrow |
| Bring hidden back | "Show N hidden" at the bottom of the sidebar |
| Only your PRs | Person toggle in the toolbar |
| Settings | ⌘, → API key, model, digest hours, weekdays only, open at login, GitLab |
| Menu bar | Tray icon, with `@1` next to it when 1 Linear ping is waiting: pings, top items, Send digest now, Refresh, Quit |

**The three columns:**

```
┌──────────────┬───────────────────────────┬──────────────────────────────────┐
│ Sidebar      │ Inbox (grouped by PR)     │ Detail                           │
│              │                           │                                  │
│ Everything 13│ remote-flows #1392   🔇3  │ ✖ CI failing  High               │
│ New at 12:00 │   ✖ Tests with Coverage…  │ Tests with Coverage is failing   │
│ CI failing  1│ remote-flows #1385   🔇4  │ [Explain] [Copy prompt] [Snooze] │
│ Merge confl 6│   ⤴ Conflicts with base   │                                  │
│ …            │   ⚙ cursor: GBR schema…   │ Claude's answer (after Explain)  │
│ GitHub       │                           │ Evidence cards (checks, comments)│
│  remote-flows│                           │                                  │
│ GitLab       │ web !12              🔇1  │                                  │
│  web         │   ✖ Pipeline is failing   │                                  │
└──────────────┴───────────────────────────┴──────────────────────────────────┘
```

The PR header shows 🔇 N (bot comments muted as noise) and 🕐 N (checks still running). GitLab merge
requests are numbered `!12`, GitHub PRs `#12`.

---

## 3. Project layout

```
triage/
├── Package.swift                  ← like package.json / mix.exs
├── Sources/
│   ├── TriageCore/                ← pure logic library, no UI (like a lib/ app in an umbrella)
│   │   ├── Models.swift           ← types: PullRequest, AttentionItem, Severity…
│   │   ├── Forge.swift            ← ForgeClient protocol, what each forge can do, the GitHub/GitLab adapters
│   │   ├── GitHubClient.swift     ← GraphQL + REST calls, token lookup
│   │   ├── GitLabClient.swift     ← GitLab GraphQL: your MRs → PullRequest
│   │   ├── LinearClient.swift     ← Linear GraphQL: your notifications from the last 30 days
│   │   ├── LinearPings.swift      ← notifications → the mentions and replies still waiting on you
│   │   ├── Classifier.swift       ← PR snapshot → attention items (the rules)
│   │   ├── PromptBuilder.swift    ← evidence + logs + diff → one prompt string
│   │   ├── AnthropicClient.swift  ← Messages API call + Keychain helper
│   │   └── Digest.swift           ← "what's new since last time" + schedule math
│   └── Triage/                    ← the macOS app (UI + state)
│       ├── TriageApp.swift        ← entry point: windows, menu bar, settings scenes
│       ├── AppDelegate.swift      ← app lifecycle, notifications, login item
│       ├── AppStore.swift         ← the state store (think Zustand/MobX store)
│       ├── ContentView.swift      ← sidebar + inbox list
│       ├── ItemDetailView.swift   ← detail pane + actions
│       ├── LinearPingViews.swift  ← Linear ping list, row and detail
│       └── SettingsView.swift     ← ⌘, window
├── Tests/TriageCoreTests/         ← Classifier + Digest tests (like ExUnit / Jest)
├── Resources/AppIcon.svg|png      ← app icon source + 1024px render
└── scripts/
    ├── bundle.sh                  ← builds ~/Applications/Triage.app
    └── render-icon.sh             ← SVG → PNG via headless Chrome
```

**Why two targets?** `TriageCore` has no UI and no app state, so it can be unit-tested and later
ported or replaced by the backend without touching views. `Triage` depends on it (`import TriageCore`).
This works like an Elixir umbrella where `core` doesn't depend on `web`.

---

## 4. Swift cheat sheet for a TS/React/Elixir developer

| Swift | Closest thing you know |
|---|---|
| `struct PullRequest { … }` | A TS `type` / Elixir struct. **Value type**: copied on assignment, like immutable data |
| `class AppStore` | A mutable object shared by reference |
| `enum AttentionKind { case ciFailure, … }` | TS string-literal union / Elixir atoms, but it can have methods |
| `enum ExplainState { case done(String); case failed(String) }` | Tagged union / `{:ok, v}` / `{:error, e}` |
| `switch x { case .done(let text): … }` | Elixir `case` pattern match; the compiler checks it's exhaustive |
| `String?` (optional) | `string \| undefined`; `if let x = maybe { }` is a guarded unwrap |
| `guard cond else { return }` | Early return / `with` clause bail-out |
| `protocol Codable` | Like a TS type + zod schema: JSON encode/decode is generated for you |
| `async` / `await` | Same as JS |
| `withTaskGroup` | `Promise.all` |
| `Task { … }` | Firing an async function without awaiting it (`void doThing()`) |
| `@MainActor` | "Runs on the UI thread", like guaranteeing code runs in the React render/event loop |
| `Sendable` | "Safe to pass between threads", like data you'd pass to a Web Worker |
| `extension Severity { var color … }` | Adding methods to an existing type (like Elixir protocols, loosely) |
| `Package.swift` / `swift build` | `package.json` / `npm run build`, `mix.exs` / `mix compile` |
| `swift test` with `@Test` / `#expect` | `mix test` with `test "…"` / `assert` |

### SwiftUI ↔ React

| SwiftUI | React |
|---|---|
| `struct ItemRow: View { var body: some View { … } }` | `function ItemRow(props) { return <…/> }` |
| `let item: AttentionItem` on a view | Props |
| `@State private var copied` | `useState` |
| `@Observable class AppStore` | A MobX/Zustand store. Views re-render when a property they **read** changes, with no selectors needed |
| `.environment(store)` + `@Environment(AppStore.self)` | Context Provider + `useContext` |
| `@Bindable var store` → `$store.onlyMine` | Passing `[value, setValue]` to a controlled input |
| `.task { … }` / `.onAppear` | `useEffect(() => { … }, [])` |
| `ForEach(items) { … }` | `items.map(i => …)` (`Identifiable` gives the `key`) |
| `if … { A } else { B }` inside `body` | Conditional JSX |
| Modifiers: `.font(.caption).foregroundStyle(.secondary)` | Styles/classNames, but chained and applied in order |
| `NavigationSplitView { sidebar } content: { … } detail: { … }` | A 3-column layout component |

---

## 5. End-to-end data flow

```
 AppDelegate.applicationDidFinishLaunching
        │
        ▼
 AppStore.startAutoRefresh()  ── loop every 120s ─────────────────────────────┐
        │                                                                     │
        ▼                                                                     │
 refresh()                                                                    │
   GitHub and GitLab in parallel (async let ≈ Promise.all), each a           │
   ForgeClient; one failing doesn't lose the other's data:                    │
   GitHub:                                                                    │
     1. token  = GitHubAuth.resolveToken() ($GITHUB_TOKEN or `gh auth token`) │
     2. viewer = login (once, for "Only my PRs")                              │
     3. for each watched repo, in parallel: 1 GraphQL query per repo          │
   GitLab (if on in Settings):                                                │
     1. token  = GITLAB_TOKEN or the Keychain (read once per session)         │
     2. viewer = username (once; it's usually not your GitHub login)          │
     3. 1 list query (your MRs), then 1 detail query per MR, in parallel      │
   4. for each PR: Classifier.classify(pr, viewer for its forge) → items      │
   5. store.items = …  → SwiftUI re-renders whatever reads items              │
   6. drop dismissed/snoozed ids that no longer exist                         │
        │                                                                     │
        ▼                                                                     │
 sendDigestIfDue()  → maybe a macOS notification (see §9)  ◄──────────────────┘

 User clicks "Explain & propose fix"
        │
        ▼
 AppStore.explain(item)
   1. buildPrompt(item, .explain)
        - CI failure: fetch job logs (REST) for up to 3 failing checks
        - fetch the PR diff (REST)
        - (GitLab MRs skip both for now: see docs/plans/GITLAB.md › Still missing)
        - PromptBuilder.prompt(...)  → one big string
   2. AnthropicClient.complete(system:prompt:)  → POST /v1/messages
   3. explanations[item.id] = .done(text)  → detail pane renders it
```

---

## 6. The core modules

### 6.1 Models (`Models.swift`)

Plain data types, all `Sendable` value types:

- `RepoRef` is `owner/name` plus its `forge` (`.github` or `.gitlab(host:)`). Its parser accepts `acme/web`
  or `https://github.com/acme/web.git`. A GitLab owner can nest (`group/subgroup`). `RepoRef.id` is what
  dismissals, snoozes and seen PRs are keyed by: plain `owner/name` for GitHub (unchanged since before
  GitLab), `host/group/project` for GitLab, so the two can never collide. GitHub repos save to JSON exactly
  as they always did.
- `PullRequest` is a snapshot: title, author, head SHA, `mergeable`, `reviewDecision`, plus
  `checks: [CheckInfo]`, `threads: [ReviewThreadInfo]` and `comments: [CommentInfo]`. It's the same shape for
  a GitHub PR and a GitLab MR; `pr.ref` writes the number the forge's way (`#12` / `!12`).
- `CheckInfo.state` is normalized to `success | failure | pending | neutral`. GitHub has two different
  systems (Check Runs and commit Statuses), and both map into this one shape.
- `AttentionItem` holds `id`, `kind`, `severity`, the `pr`, a one-line `headline`, and `evidence` (the
  failing checks / comments that justify it).
- `Severity` runs `info < low < medium < high` and drives sorting, colors, and what the menu bar counts.

### 6.2 Forges: one interface, two services (`Forge.swift`)

The app never calls GitHub or GitLab directly. It talks to a `ForgeClient` protocol (≈ a TypeScript
interface), and `GitHubForge` and `GitLabForge` are adapters behind it:

```swift
protocol ForgeClient {
    var forge: Forge { get }                        // .github or .gitlab(host:)
    func viewer() async throws -> String            // who "you" are there
    func fetch() async throws -> [RepoResult]       // open PRs, one result per repo/project
    func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String?
    func diff(_ pr: PullRequest) async -> String?
    func approve(_ pr: PullRequest) async throws
    func merge(_ pr: PullRequest) async throws
    func close(_ pr: PullRequest) async throws
}
```

- **`fetch()` hides how each forge fetches.** GitHub runs one query per watched repo; GitLab one query for
  "my MRs" across all projects, grouped into one result per project.
- **Capabilities** (`Forge.capabilities`, an option set of `ciLogs`, `diff`, `checkout`, `approve`, `merge`,
  `close`) say what Triage can do for a forge's PRs. GitHub has all of them; GitLab has none yet, so its
  merge requests are read-only. Views ask `store.can(.merge, pr)` and **hide** what's missing, rather than
  showing a button that fails. Turning a GitLab feature on is implementing the method and adding the
  capability (see `docs/plans/GITLAB.md` › Still missing).
- **Wording** comes from the forge too: `forge.name` ("GitHub"/"GitLab"), `numberPrefix` (`#`/`!`),
  `pullRequestsName`, and `forge.cli("checkout", n)` (`gh pr checkout n` / `glab mr checkout n`) for prompts.

### 6.3 GitHub client (`GitHubClient.swift`)

**Auth (prototype):** `$GITHUB_TOKEN`, else it shells out to `gh auth token`. So it acts as *you*, with
whatever repos your `gh` login can see.

**One GraphQL query per repo** fetches everything classification needs in a single round trip:

```graphql
repository(owner, name) {
  pullRequests(states: OPEN, first: 30, orderBy: UPDATED_AT DESC) {
    number title url isDraft mergeable reviewDecision headRefName author
    commits(last: 1) → statusCheckRollup.contexts(first: 60)   # CheckRun | StatusContext
    reviewThreads(first: 50) → isResolved isOutdated path line + first comment
    comments(last: 20) → author (login + __typename: User | Bot) body url
  }
}
```

The JSON is decoded into private `Decodable` structs (`PRNode`, `ContextNode`, …) that mirror the query.
`toModel()` then converts them into the clean `PullRequest` model. This works like a GraphQL response
type plus a mapper function, so the rest of the app never sees GitHub's shape.

**REST calls** are made only when building a prompt:

| Call | Used for |
|---|---|
| `GET /repos/{r}/actions/jobs/{id}/logs` | Raw log of a failed GitHub Actions job (check run id == job id) |
| `GET /repos/{r}/check-runs/{id}` | Fallback for non-Actions checks: their published title/summary/text |
| `GET /repos/{r}/pulls/{n}` with `Accept: …diff` | The PR diff |

**Bot detection:** an author is a bot if GraphQL says `__typename == "Bot"` or the login ends in `[bot]`.

### 6.4 GitLab client (`GitLabClient.swift`)

**Auth:** a personal access token with the `read_api` scope, from `$GITLAB_TOKEN` or the Keychain
(service `dev.rogal.triage.gitlab`, account = host), pasted in Settings → GitLab. The app reads it once per
session and keeps it in memory.

**Two steps per refresh**, because GitLab caps a query's complexity at 250 and nesting jobs and discussions
for 50 MRs goes far over it:

1. A cheap list query (complexity ~28): `currentUser { assignedMergeRequests, reviewRequestedMergeRequests }`,
   50 each, open, most recently updated first. An MR in both lists is fetched once.
2. One detail query per MR, in parallel (complexity ~78 each): pipeline jobs, discussions with their notes,
   approvals, reviewers' review state, merge status.

One MR failing to load becomes a warning; all of them failing (bad token, instance down) is one "GitLab: …"
error. The GitHub data stays either way.

**Mapping onto `PullRequest`** (`MRNode.toModel`), where GitLab differs from GitHub:

| GitLab | Becomes |
|---|---|
| `iid` | `number`, shown as `!12` |
| Pipeline jobs | `checks` (allow-failure jobs are neutral; the job id is kept for logs later) |
| A pipeline that failed or is running with no job saying so (a config error, a downstream pipeline) | one extra "Pipeline" check, so the MR can't read as green |
| Resolvable discussions | `threads`; plain comments → `comments` |
| **System notes** ("added 3 commits", "changed the title") | dropped: otherwise every push would change item ids |
| A reviewer's `REQUESTED_CHANGES` | `reviewDecision = .changesRequested` |
| `approvalsLeft > 0` / someone approved | `.reviewRequired` / `.approved`. With no approval rules GitLab calls every MR "approved"; that alone isn't enough |
| `detailedMergeStatus` `CONFLICT`, `NEED_REBASE` / `CHECKING`… | `.conflicting` / `.unknown` |
| Access-token bots (`project_<id>_bot_<hash>`) | a bot, named by its display name (`cursor` for Cursor Bugbot, as on GitHub) |

Threads are never marked outdated: GitLab has no simple flag, and guessing would hide real unresolved threads
after a push.

### 6.5 Classifier (`Classifier.swift`), the heart of it

`Classifier.classify(pr) -> (items, stats)`: a pure function with no I/O. It's easy to test, and it's
the piece most likely to move to the backend later.

| Rule | Item kind | Severity | Item id (dedup key) |
|---|---|---|---|
| Any check with state `failure` | CI failing (all failures on the commit → **one** item) | high (medium if draft) | `pr\|ci\|<headSha>` |
| `mergeable == CONFLICTING` | Merge conflict | high | `pr\|conflict\|<headSha>` |
| `reviewDecision == CHANGES_REQUESTED` | Changes requested | high | `pr\|changes\|<headSha>` |
| Unresolved, not outdated thread started by a **human** | Unresolved review (all threads → one item) | medium | `pr\|threads\|<latest thread url>` |
| Comment or unresolved thread by a **non-noise bot** | Bot finding (one item **per bot**) | from the bot's own label, see below | `pr\|bot\|<login>\|<latest url>` |
| Nothing else open + approved + mergeable + all checks green + not draft | Ready to merge | info | `pr\|ready\|<headSha>` |
| Opened by someone else after the repo was first fetched, not dismissed yet (`SeenPRs`) | New PR (next to any other item) | low | `pr\|new` |

**Noise bots** are counted in `PRStats.noiseComments` and never become items: `codecov`, `vercel`,
`netlify`, `github-actions`, `changeset-bot`, `dependabot`, `renovate`, `sonarcloud`, `linear`,
`cla-assistant`, `height`, `graphite-app`. On `remote-flows` this mutes ~107 coverage-report comments.

**Bot severity:** if the comment says "High/Critical Severity", "Medium Severity" or "Low Severity"
(as Cursor Bugbot does), that label is used. Otherwise it's *medium* if the text mentions
error/fail/vulnerability/critical/security/breaking/bug, else *low*. The headline uses the finding's
first markdown heading, e.g. `cursor: GBR schema pin exceeds latest version`.

**Why the ids matter.** An id encodes *the situation*, not just the PR:

- Dismiss "CI failing" on commit `abc`, then push commit `def` that still fails: the new id
  `…|ci|def` is a new item, so it comes back. That's what you want, because it's new information.
- A new review thread changes the "latest thread url", so the threads item re-appears.
- The same item on the next refresh keeps its id, so it stays dismissed.

It's the same idea as a React `key` or an idempotency key: stable while nothing changed, new when
something did. Both dismissals and the digest's "what's new" are built on this.

The classifier doesn't know which forge a PR came from. It gets the viewer for the PR's forge (your GitHub
login or your GitLab username), and the forge-specific work (system notes, pipeline checks, review state) is
done in the mapping, so the same rules and ids work for both.

### 6.6 Prompt builder (`PromptBuilder.swift`)

This follows the same pattern as expenses-backend's `get_*_prompt` MCP tools: **assemble all the
evidence into one string**, so whoever reads it (Claude, or you) doesn't need to fetch anything.

The structure of a prompt:

```
You're on PR #1392 in remoteoss/remote-flows: "chore(deps-dev): update dependency jsdom…"
Author · branch · head sha · url
Problem: CI failing — Tests with Coverage is failing

## Evidence            ← each evidence card (check name + url, comment bodies)
## Output of <check> (last 250 of N lines)   ← log tail; the failure is almost always at the end
## PR diff (first 60000 of N characters)     ← labelled when clipped
## Task                ← depends on the mode
```

Two modes:

- **`.explain`** (sent to Claude from the app): explain in 2–4 sentences, classify it (real bug / flaky
  or infra / needs a human decision), propose a fix as a unified diff, and draft a PR reply.
- **`.claudeCode`** (copied to the clipboard): `gh pr checkout N`, read the code, propose a fix, **wait
  for approval**, then fix, test, commit and push to the branch.

The system prompt tells Claude to be concrete and to say when a failure looks flaky or unrelated
(recommend a rerun rather than a code change).

### 6.7 Anthropic client (`AnthropicClient.swift`)

Raw HTTP, because there's no official Swift SDK. It's one non-streaming `POST
https://api.anthropic.com/v1/messages`:

```json
{ "model": "claude-opus-5", "max_tokens": 16000, "fallbacks": "default",
  "system": "<triage system prompt>", "messages": [{ "role": "user", "content": "<prompt>" }] }
```

The headers are `x-api-key`, `anthropic-version: 2023-06-01` and
`anthropic-beta: server-side-fallback-2026-07-01`. The fallback means that if Claude's safety
classifiers decline, the server reruns the request on a recommended fallback model instead of failing.
The response's `text` blocks are joined and returned. A `stop_reason: "refusal"` becomes a readable error.

- **When it's called:** only on "Explain & propose fix". Refresh, classification, copy buttons and
  digests never call Anthropic.
- **Key lookup**, in priority order (Settings shows which one is active):
  1. **Key source** (Settings): either a 1Password reference (`op://Vault/Item/field`, read with `op read`
     and Touch ID) or a **key helper script** that prints the key. That's the same contract as Claude Code's
     `apiKeyHelper`. It's set to `~/.claude/anthropic_key.sh`, the work helper, which reads the Keychain first
     and falls back to 1Password. The key is kept **in memory only** for the session, and a 401 clears it
     so a rotated key gets re-read.
  2. `$ANTHROPIC_API_KEY`: only visible when started from a terminal (`swift run`). Apps opened with
     `open`/Finder/Dock don't inherit shell variables, so the bundled app won't see keys from `.zshrc`.
  3. A key pasted in Settings, stored in the macOS **Keychain** (the OS's encrypted secret store).
- **Model:** editable in Settings (default `claude-opus-5`).

### 6.8 Digest (`Digest.swift`)

Two pure functions:

- `DigestBuilder.build(current:previousIDs:since:)` diffs two sets of item ids:
  - **new** = open now, not open at the previous digest → listed (top 3, most severe first, "+N more")
  - **cleared** = open then, gone now (fixed, merged, dismissed or superseded by a push) → counted
  - title `"3 new since 12:00"` or `"Nothing new since 12:00"`; last line `"13 open · 4 cleared"`
- `DigestBuilder.latestSlot(atOrBefore:hours:weekdaysOnly:)`: the most recent scheduled time. At 14:05 with
  `[12, 18]` it's today 12:00. On Monday 09:00 with weekdays only, it's Friday 18:00.

---

### 6.9 Fix in iTerm (`Handoff.swift`)

Hands an item to a coding agent (your "harness") in a terminal, in its **own git worktree per PR**. That way
several agents can work on different PRs in parallel without touching your main checkout.

1. **Find the local clone** by looking for `<root>/<repo name>` in `~/remote`, `~/rogal`, `~/code`, … whose
   `origin` points at the repo. It's remembered per repo. Override it by right-clicking the repo in the
   sidebar → *Set local checkout…*.
2. **Write the prompt** (mode `.handoff`: "you're in a worktree on branch X; explain, propose, wait for my
   OK, then fix, test, commit and push") and a zsh script to `~/Library/Caches/dev.rogal.triage/handoffs/`.
3. **Open iTerm** (AppleScript) running that script. The script:
   - reuses `<checkout>-pr-<N>` (e.g. `~/remote/remote-flows-pr-1392`) if it exists;
   - otherwise, if the branch is already checked out somewhere (e.g. your main checkout), uses that;
   - otherwise runs `git fetch origin <branch>` + `git worktree add`; for forks, it uses `gh pr checkout`;
   - runs `git pull --ff-only`, then your **harness command**, then leaves an interactive shell open.
4. The script runs in an **interactive zsh**, so `.zshrc` functions work. In particular, your `claude` wrapper
   switches to the *work* account automatically because the worktree is under `~/remote`.

The harness command is a template in Settings, `claude "$(cat {prompt_file})"` by default. Swap it for
`cursor-agent "$(cat {prompt_file})"`, `gemini "$(cat {prompt_file})"`, etc.

The first use triggers macOS's "Triage wants to control iTerm" prompt (Automation permission).
Tests run the generated script against throwaway git repos for three cases: new worktree, reuse, and a
branch that's already checked out elsewhere.

## 7. The app layer

### 7.1 `AppStore`, the single store

`@Observable @MainActor final class AppStore`. Think of it as one MobX store that every view reads from
the environment. It holds:

- **Persisted** (saved to `UserDefaults` on every change via `didSet`): `repos`, `dismissed`, `snoozed`,
  `onlyMine`, `model`, `digestHours`, `digestWeekdaysOnly`, `digestBaseline`, `lastDigestItemIDs`,
  `lastDigestAt`, `gitlabHost` (empty = GitLab off).
- **In-memory**: `prs`, `items`, `stats`, `viewer` (GitHub) and `gitlabViewer`, `isRefreshing`, `errors`,
  `explanations`, `filter`, `selection`, the cached GitLab token.
- **Derived** (computed properties, like selectors / `useMemo`):
  - `activeItems`: items minus dismissed, minus snoozed-until-future, minus others' PRs if "Only mine",
    sorted by severity then recency.
  - `visibleItems`: `activeItems` narrowed by the sidebar filter (all / kind / repo / last digest).
  - `groupedVisible`: grouped by PR for the inbox sections.
  - `summaryLine`: "13 need you · 0 PRs waiting on CI · 107 bot comments muted".
  - `gitlabProjects`: the GitLab projects with an MR for you, for the sidebar.
  - `viewer(for: forge)` and `can(capability, pr)`: who you are on a PR's forge, and what Triage may do.
- **Actions**: `refresh`, `addRepo`, `removeRepo`, `dismiss`, `snooze`, `restoreHidden`, `explain`,
  `copyPrompt`, `sendDigestIfDue`, `sendDigest`, `showMainWindow`, `saveGitLabToken`. PR actions (approve,
  merge, close) go through `forgeClient(_:repos:)` (`AppStore+Forge.swift`).

### 7.2 Views

- **`TriageApp`**: the `@main` entry. It declares three *scenes*: the main `Window`, the `MenuBarExtra`
  (tray icon + menu) and `Settings`. It injects the store with `.environment(delegate.store)`.
- **`ContentView`**: `NavigationSplitView` with `Sidebar`, `InboxList` (sections per PR, `PRHeader` +
  `ItemRow`s) and `ItemDetailView`, plus the toolbar (summary, Only mine, Refresh). The sidebar has a
  **GitHub** section (the repos you watch) and, when it's on, a **GitLab** section (projects by name, from
  the fetch; nothing to add or remove).
- **`ItemDetailView`**: header, action buttons with keyboard shortcuts, Claude's answer (loading / done /
  failed), and evidence cards. Markdown in comments/answers is rendered inline. Buttons the PR's forge can't
  do are hidden: for a GitLab MR that's Approve, Merge, Close and Fix in iTerm, and Explain PR copies a
  prompt instead of opening iTerm.
- **`SettingsView`**: API key → Keychain, model, digest hours, weekdays only, open at login, "send a
  digest now", GitLab (on/off, host, token → Keychain, Test, "Signed in as …"), and which GitHub token source
  is in use.

A quirk worth knowing: `Text("#\(number)")` in SwiftUI is *localized*, so numbers get thousands
separators (`#1.392`). Use `Text(verbatim:)` or `String(…)` for ids.

### 7.3 `AppDelegate`: lifecycle, notifications, login item

- **It owns the store**, not a view. If a view owned the store, closing the window would stop the
  refresh loop and digests would stop too. With the delegate owning it, the app keeps running from the
  menu bar with no window open.
- It requests notification permission and handles clicks: set filter → "New at 12:00", select the
  first item, reopen the main window.
- `willPresent` makes banners show even when Triage is the frontmost app (macOS hides them by default).
- `LoginItem` wraps `SMAppService.mainApp` for "Open Triage at login".
- Reopening a closed window needs SwiftUI's `openWindow`, which only exists inside views. The menu bar
  label is always rendered, so it hands `openWindow` to the store (`store.openMainWindow`).

---

## 8. Persistence: what's stored where

| Data | Where | Notes |
|---|---|---|
| Watched repos, dismissed/snoozed ids, prefs, digest state | `UserDefaults`, domain `dev.rogal.triage` | Like `localStorage`. Inspect with `defaults read dev.rogal.triage` |
| Anthropic API key via 1Password | Only the `op://` reference in `UserDefaults`; the key lives in memory | Touch ID once per app session |
| Anthropic API key (if pasted in Settings) | Keychain, service `dev.rogal.triage` | Encrypted by macOS |
| GitHub token | Not stored; read from `$GITHUB_TOKEN` / `gh` each refresh | |
| GitLab host | `UserDefaults` key `gitlabHost` | Empty means GitLab is off |
| GitLab token | Keychain, service `dev.rogal.triage.gitlab`, account = host (or `$GITLAB_TOKEN`) | Read once per app session, then kept in memory. macOS may ask once to let Triage use it |
| PRs, items, Claude answers | Memory only | Refetched on launch; answers are lost on quit |

Stale dismissals are cleaned up on each refresh: once an item id no longer exists, it's dropped.

---

## 9. Digest notifications in detail

```
every refresh (2 min):
  if refresh failed for every repo      → skip (don't digest stale data)
  if no baseline yet (first launch)     → save current ids as baseline silently, stop
  slot = latest 12:00/18:00 at or before now (skipping weekends if weekdays only)
  if lastDigestAt < slot                → build digest vs baseline, send notification,
                                          baseline = current ids, lastDigestAt = now,
                                          lastDigestItemIDs = the "new" ones
```

- **Missed slots catch up:** asleep or closed at 12:00 → it sends on the first refresh after that.
  Several missed slots produce one digest, not a burst.
- **Click** → app opens on the "New at 12:00" sidebar filter.
- **Send digest now** (menu bar or Settings) refreshes and sends immediately. It also resets the
  baseline, so it's safe for testing.
- Notifications require the **bundled** app (see §10). A bare `swift run` binary has no bundle id, so
  `Notifier.isAvailable` is false and they're skipped rather than crashing.

---

## 10. Build, packaging and tooling

| Command | What it does |
|---|---|
| `triage` | `scripts/bundle.sh` + quit the running app + `open ~/Applications/Triage.app` |
| `scripts/bundle.sh` | `swift build -c release` → creates `Triage.app/Contents/{MacOS,Resources,Info.plist}`, builds `AppIcon.icns` from the PNG with `sips` + `iconutil`, codesigns with the stable `Triage Local Signing` identity from `scripts/setup-signing.sh` (ad-hoc fallback), migrates old settings once |
| `scripts/render-icon.sh` | Renders `Resources/AppIcon.svg` → `AppIcon.png` (1024px, transparent) with headless Chrome |
| `swift run Triage` | Quick dev run, no bundle (no notifications or login item) |
| `swift test` | Swift Testing suite: classifier rules, dedup ids, bot severity, prompt assembly, digest diff and schedule, GitHub and GitLab decoding (fixtures, no network), forge ids and wording |

An `.app` is only a folder with a known layout. `Info.plist` gives it an identity (`dev.rogal.triage`),
which macOS needs for notifications, Keychain scoping, login items and the icon. There's no Xcode
project; SwiftPM + a shell script is enough for a personal tool.

---

## 11. Network and cost profile

| Trigger | Calls | Cost |
|---|---|---|
| Every 2 min | 1 GraphQL query per watched repo (+1 viewer query once) | Free; well within GitHub's 5,000 points/hour |
| Every 2 min, GitLab on | 1 list query + 1 detail query per MR for you (+1 viewer query once) | Free; gitlab.com allows 2,000 requests/min |
| Explain | 1–3 job-log fetches + 1 diff fetch + **1 Claude request** | One Opus request per click (prompt up to ~60KB of diff + log tails) |
| Copy prompt | Same GitHub fetches, no Claude call | Free |
| Digest | Nothing extra (uses the latest refresh) | Free |

---

## 12. Known limits of the prototype

- **Fetch caps:** 30 most recently updated open PRs per repo, 60 checks, 50 review threads (first
  comment only), last 20 PR comments. There's no pagination yet.
- **"Unresolved review" can't tell if you already replied.** It only looks at the thread's first
  comment and `isResolved`.
- **"Only my PRs" = authored by you.** "Review requested from me" isn't modelled yet.
- **Rules are heuristics.** The noise-bot list and severity keywords will need tuning per team.
- **Single user, local tokens.** It uses your `gh` token and your API key, and there's no server.
- **Timing:** macOS may delay a sleeping app's timers (App Nap), so a digest can arrive a few minutes
  late.
- **Claude answers aren't saved**, and "Fix it" (an agent that pushes a commit) doesn't exist yet.
- **GitLab is read-only.** No diff or CI logs in prompts, no Fix in iTerm, no approve/merge/close, and
  reviewer MRs aren't flagged as "waiting for your review" yet. Each is written up, with how to build it, in
  `docs/plans/GITLAB.md` › Still missing.

---

## 13. Where it goes next: the Phoenix backend (multi-tenant)

The Swift app becomes a thin client. What moves server-side maps directly onto patterns you know from
expenses-backend:

| Today (in the app) | Backend equivalent |
|---|---|
| `gh auth token` | **GitHub App**: users install it on repos; per-installation tokens; "Sign in with GitHub" |
| Poll every 2 min | **Webhooks** (`pull_request`, `check_run`, `pull_request_review_thread`, `issue_comment`) → controller verifies signature → **Oban** job; plus a reconcile cron for dropped webhooks |
| `PullRequest` snapshot | `pull_requests` table (Finders/Handlers/Services/Values layering) |
| Raw events | `signals` table |
| `Classifier.classify` | Same rules as an Elixir module (pure function, ported 1:1) |
| `AttentionItem` + dismissed/snoozed | `attention_items` table with a `status` column, per user |
| `PromptBuilder` | `get_attention_prompt(item)`, same read-prompt pattern as `get_holding_analysis_prompt`, exposed via REST **and** MCP |
| Digest timer | Oban cron per user; deliver via push notification / Telegram |
| Store refresh | **Phoenix Channels** push new items to the app live |
| "Explain" | Server calls Claude, stores the answer (`agent_runs` table) |
| — (new) "Fix it" | Server-side agent loop: Claude + tools that are **GitHub API calls** (read file, search code, get logs, commit to branch). The PR's CI is the test runner, so no clones or sandboxes are needed. Status: `fixing` → `resolved` / back to `new` |

The Swift code is already split to make this easy: `TriageCore`'s client, classifier and prompt
builder are the parts that move. The views and `AppStore` stay, with `refresh()` calling your API instead
of GitHub.
