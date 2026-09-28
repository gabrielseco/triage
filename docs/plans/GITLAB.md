# Plan: GitLab merge requests assigned to me

Status: plan agreed, nothing built yet. Date: 2026-09-28.

## Goal

Show open merge requests from a private GitLab project in the Triage inbox, alongside GitHub PRs, when they're
**assigned to me**, and classify them the same way: CI failing, conflict, changes requested, unresolved
threads, ready to merge, and so on.

## Decisions

1. **Host: gitlab.com.** Base URL `https://gitlab.com`, `/api/graphql` and `/api/v4`. The host still lives on
   `Forge.gitlab(host:)` so a self-managed instance is a setting, not a rewrite.
2. **"Assigned to me":** watch both assignee and reviewer MRs, and tag each MR with why it's there. Assignee MRs
   behave like "Mine" today. Reviewer MRs are what "Waiting for review" means for someone else's PR.
3. **Tier: Premium/Ultimate (work account), always the latest version on gitlab.com.** Approval rules
   (`approvalsLeft`) and the reviewer `REQUESTED_CHANGES` state are available, so "Changes requested" and
   "Ready to merge" work as on GitHub. Keep the rule anyway: without approval info, never emit `readyToMerge`.
4. **Read-only first, features behind capabilities.** GitLab starts with every action off (see
   [Adapter](#adapter-one-interface-per-forge)); each phase turns one on. Watching needs `read_api`; the `api`
   scope comes with the first write action.

## How GitHub works today (what has to change)

| Area | Today | GitLab impact |
| --- | --- | --- |
| What's watched | `repos: [RepoRef]`, one GraphQL query per repo every 120 s (`AppStore.refreshOnce` → `fetchAll`) | GitLab is better as **one query for "my MRs"** across all projects, not per repo |
| Repo identity | `RepoRef(owner, name)`, `fullName = owner/name`, parsed by splitting on `/` | GitLab paths nest (`group/sub/project`), so two parts isn't enough. Needs host + full path |
| PR id | `"\(repo.fullName)#\(number)"`, the base of every `AttentionItem.id` | Must include the host so a GitLab `group/app` can't collide with a GitHub `group/app`. **GitHub ids must stay unchanged**, or dismissals and snoozes reset |
| Auth | `GitHubAuth.resolveToken()`: `GITHUB_TOKEN` or `gh auth token` | New token: a GitLab PAT, via Keychain or a key reference (`op://`, helper), as the Anthropic key already works |
| Client | `GitHubClient`: GraphQL for the snapshot, REST for job logs, check output, diff, merge and close | New `GitLabClient` with the same shape |
| Links | `changesURL = url + /changes`, `CIStatus` → Checks tab | GitLab: `/-/merge_requests/N/diffs` and `/-/merge_requests/N/pipelines` |
| Merge | `MergeMethod` merge/squash/rebase, `mergeBlocker` / `mergeWarnings` text mentions GitHub | GitLab: merge, rebase_merge, ff + squash flag; blockers come from `detailedMergeStatus` |
| Handoff | `gh pr checkout N` in `Handoff.swift` and the prompts (`PromptBuilder` lines 66, 116) | `glab mr checkout N`, or plain `git fetch origin <source_branch>` (no forks, so the branch is on origin) |
| Checkout paths | `checkoutPaths[repo.fullName]` | Key by the new host-aware id |
| Bots | `Classifier` noise set of GitHub logins | GitLab bots: `user.bot == true`, `project_<id>_bot*`, plus the same review bots by name |

## Mapping a GitLab MR onto `PullRequest`

The Classifier stays provider-agnostic if the mapping is right, so most of the work is here, in `TriageCore`
and tested.

| `PullRequest` field | GitLab GraphQL (`MergeRequest`) | Notes |
| --- | --- | --- |
| `number` | `iid` | Displayed as `!12`, not `#12` |
| `title`, `summary` | `title`, `description` | `PRSummary` should work unchanged |
| `url` | `webUrl` | |
| `author`, `authorAvatar` | `author { username avatarUrl }` | Self-hosted `avatarUrl` can be relative, so prefix the host |
| `isDraft` | `draft` | |
| `createdAt`, `updatedAt` | same | |
| `headSha`, `headRef` | `diffHeadSha`, `sourceBranch` | |
| `mergeable` | `detailedMergeStatus`: `conflict` / `need_rebase` → `.conflicting`, `checking` / `unchecked` → `.unknown` | Other states (`not_approved`, `discussions_not_resolved`, `ci_must_pass`) become merge warnings |
| `reviewDecision` | `approved` / `approvalsLeft` → `.approved` / `.reviewRequired`; any reviewer with `mergeRequestInteraction.reviewState == REQUESTED_CHANGES` → `.changesRequested` | See open question 3 |
| `checks` | `headPipeline { status jobs { nodes { id name status webUrl } } }` | Job status → `CheckState`. `id` → `checkRunID`, so the job log (`/projects/:id/jobs/:id/trace`) feeds the CI prompt |
| `threads` | `discussions { resolvable resolved notes { author body position { newPath newLine } } }` for diff/resolvable discussions | `isOutdated`: compare `position.headSha` with `diffHeadSha` (approximate) |
| `comments` | Non-resolvable discussions' notes, **excluding `system: true`** | System notes ("added 3 commits", "changed title") would otherwise all look like new comments and churn item ids |
| `mergeMethod` | `project { mergeMethod squashOption }` | Needs a GitLab variant or a provider-neutral enum |

Item-id rules carry over unchanged: `<pr.id>|<kind>|<headSha or latest non-bot, non-viewer comment id>`. Add a
Classifier test with a GitLab-shaped fixture, including "system notes don't change the id".

## Fetching

One GraphQL query per refresh for the whole account:

```graphql
query {
  currentUser {
    username
    assignedMergeRequests(state: opened, first: 50) { nodes { ...MR } pageInfo { hasNextPage } }
    reviewRequestedMergeRequests(state: opened, first: 50) { nodes { ...MR } pageInfo { hasNextPage } }
  }
}
```

- Deduplicate by id (you can be both assignee and reviewer) and keep a `why: assignee | reviewer` on it.
- **Complexity limit:** GitLab caps a query's complexity (250 by default when authenticated). Nested jobs and
  discussions for 50 MRs will likely exceed it. Plan: first query lists MR ids plus cheap fields, then one detail
  query per MR that changed since the last refresh (compare `updatedAt`). Measure it on the real instance
  before choosing. Truncation (`hasNextPage`, job/discussion caps) goes into `RepoSnapshot.warnings`, as GitHub does.
- Rate limits are per minute and generous (gitlab.com: 2,000 authenticated requests/min), so a 120 s refresh is
  safe even with per-MR detail queries.
- Optional: limit to chosen projects (a project filter in Settings) if "assigned to me" pulls in too much.

## Adapter: one interface per forge

The app talks to a `ForgeClient` protocol; `GitHubClient` and `GitLabClient` implement it. Everything above the
client (Classifier, AppStore, views) sees only `PullRequest`, `RepoSnapshot` and the protocol, so GitLab is
"just another adapter".

```swift
public protocol ForgeClient: Sendable {
    var forge: Forge { get }
    var capabilities: ForgeCapabilities { get }

    func viewer() async throws -> String
    /// GitHub: one query per watched repo. GitLab: one "my MRs" query, grouped into snapshots per project.
    func fetch() async -> [RepoResult]

    /// GitHub: the Actions job log, or the check run's output for other checks.
    func ciLog(_ pr: PullRequest, check: CheckInfo) async -> String?
    func diff(_ pr: PullRequest) async -> String?
    func approve(_ pr: PullRequest) async throws
    func merge(_ pr: PullRequest, method: MergeMethod) async throws
    func close(_ pr: PullRequest) async throws
    /// The shell command that checks the branch out, for Handoff and the prompts.
    func checkoutCommand(_ pr: PullRequest) -> String
}

public struct ForgeCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public static let ciLogs = Self(rawValue: 1 << 0)
    // diff, checkout, approve, merge, close likewise
}
```

- **`fetch()` hides the fetching difference.** GitHub keeps its per-repo loop inside the adapter; GitLab runs
  the account-wide query. `AppStore.refreshOnce` just calls `fetch()` on every configured client in parallel
  and merges results. A failing client goes to `errors` without losing the others' data.
- **Methods take a `PullRequest`, not `(RepoRef, number)`,** so each adapter reads what it needs (`iid`,
  project id, `headSha`) without the protocol knowing about either forge.
- **Capabilities gate the UI.** `store.can(.merge, pr)` checks `client(for: pr.repo.forge).capabilities`.
  Buttons, menu items and prompt sections that need a missing capability are hidden, not disabled with an
  error. GitHub is `.all`; GitLab starts at `[]` and grows one phase at a time. Unimplemented GitLab methods
  throw `ForgeError.unsupported`, which the gating makes unreachable.
- **Wording comes from the forge,** not hardcoded GitHub text: `forge.name` ("GitHub"/"GitLab"),
  `forge.numberPrefix` (`#`/`!`), links (`/changes` vs `/-/merge_requests/N/diffs`, Checks tab vs
  `/pipelines`). Classifier headlines ("GitHub is still checking…") and `PromptBuilder` use them.
- **Refactor GitHub onto the protocol first, with no behavior change.** That's its own PR and proves the
  interface before any GitLab code exists.

### Rest of the architecture

- `TriageCore`:
  - `Forge` (`.github`, `.gitlab(host:)`) on `RepoRef`, plus a full `path` (nested groups). Keep `owner/name`
    working for GitHub. Keep the GitHub `id` and `fullName` exactly as today, and prefix only GitLab ids with the host.
  - `GitLabClient`: GraphQL for the snapshot; REST for job trace, raw diff (`/merge_requests/:iid/raw_diffs`),
    approve (`POST …/approve`), merge (`PUT …/merge` with `sha`, `squash`) and close (`state_event=close`).
  - Mapping (`GitLabMRNode.toModel`) and GitLab bot detection, all with fixture-based tests. No network in
    tests, as for GitHub.
- `Triage` app:
  - New persisted `gitlabSources: [GitLabSource]` (host, username, which roles). A **new UserDefaults key**:
    don't change `repos`' Codable shape, or `load` fails and GitHub repos silently reset.
  - GitLab token: Keychain (a new service/account), or a key reference (`op://`, helper). Never in
    UserDefaults or error text.
  - `viewer` becomes per-forge (GitHub login ≠ GitLab username) so "Mine", `newPR`, approvals and thread ids work.
  - Sidebar: under "Watching", a "GitLab" row that filters to those MRs, with projects listed from the results.
    The Settings "GitLab" section has host, token (Test button like the Anthropic key) and roles.
  - `AppStore+GitLab.swift` for the new store code, matching the `+Feature` extensions.

Rejected: running `glab` as a subprocess for data. It adds a CLI dependency, gives less control over fields and
is slower per refresh. `glab` stays only as an optional checkout command.

## Phases (one PR each)

1. **`ForgeClient` protocol, GitHub only:** extract the protocol and `ForgeCapabilities`, move `RepoResult`
   from the app target into `TriageCore`, make `GitHubClient` conform, route AppStore through it, forge-provided wording. No behavior change, GitHub ids byte-for-byte
   unchanged (test).
2. **Core model:** `Forge.gitlab(host:)` on `RepoRef`, nested paths, host-aware ids for GitLab only, old
   `repos` JSON still decodes (test). No UI.
3. **GitLab client + mapping:** query, `toModel`, bot detection, system-note filtering, Classifier fixtures.
   Measure query complexity on the work account here. Capabilities `[]`.
4. **Wire into the app, read-only:** Settings section, Keychain token, refresh, sidebar row, GitLab links. MRs
   show and classify; no actions. `/verify` + `/design-review`.
5. **Turn capabilities on, one PR each:** `.diff` + `.ciLogs` (AI summaries and fix prompts), `.checkout`
   (Handoff, extend `HandoffScriptIntegrationTests`), then `.approve`, `.merge`, `.close` (needs `api` scope,
   GitLab merge methods).

## Risks

- **Silent settings reset** if `RepoRef`'s Codable shape changes without a migration. Mitigation: a new key,
  and a decode test for old `repos` JSON.
- **Dismissals resetting** if GitHub item ids change. Mitigation: the phase 1 test.
- **Query complexity limits** forcing per-MR queries. Mitigation: measure early (spike in phase 2).
- **Interface drift:** a GitLab need that doesn't fit the protocol. Mitigation: phase 1 lands the protocol
  with GitHub alone, and the phase 3 spike checks it against real GitLab data before the app wiring.
- **Token scope/expiry:** gitlab.com PATs expire (max 1 year) and org policy may shorten it. Surface a 401
  as one clear "GitLab token expired" error, not per MR.
