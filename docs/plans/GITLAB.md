# Plan: GitLab merge requests assigned to me

Status: phases 1–4 shipped (#33–#36), GitLab MRs show read-only. Phase 5 is on hold until it's needed:
see [Still missing](#still-missing). Updated: 2026-09-28.

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
| `threads` | `discussions { resolvable resolved notes { author body position { newPath newLine } } }` for diff/resolvable discussions | `isOutdated` is always false: GitLab has no simple flag, and comparing commits would hide every unresolved thread after a push |
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

The app talks to a `ForgeClient` protocol; `GitHubForge` (wrapping today's `GitHubClient`) and `GitLabClient`
implement it. Everything above the
client (Classifier, AppStore, views) sees only `PullRequest`, `RepoSnapshot` and the protocol, so GitLab is
"just another adapter".

```swift
public protocol ForgeClient: Sendable {
    var forge: Forge { get }

    func viewer() async throws -> String
    /// GitHub: one query per watched repo. GitLab: one "my MRs" query, grouped into snapshots per project.
    func fetch() async -> [RepoResult]

    /// GitHub: the Actions job log, or the check run's output for other checks. GitLab: the job trace.
    func ciLog(_ pr: PullRequest, checkRunID: Int) async -> String?
    func diff(_ pr: PullRequest) async -> String?
    func approve(_ pr: PullRequest) async throws
    /// With `pr.mergeMethod`, pinned to `pr.headSha`.
    func merge(_ pr: PullRequest) async throws
    func close(_ pr: PullRequest) async throws
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
- **Capabilities gate the UI.** They live on `Forge` (`pr.repo.forge.capabilities`), so a view can check them
  without resolving a token.
  Buttons, menu items and prompt sections that need a missing capability are hidden, not disabled with an
  error. GitHub is `.all`; GitLab starts at `[]` and grows one phase at a time. Unimplemented GitLab methods
  throw `ForgeError.unsupported`, which the gating makes unreachable.
- **Wording comes from the forge,** not hardcoded GitHub text: `forge.name` ("GitHub"/"GitLab"),
  `forge.numberPrefix` (`#`/`!`), links (`/changes` vs `/-/merge_requests/N/diffs`, Checks tab vs
  `/pipelines`). Classifier headlines ("GitHub is still checking…") and `PromptBuilder` use them.
- **Refactor GitHub onto the protocol first, with no behavior change.** That's its own PR and proves the
  interface before any GitLab code exists. `GitHubForge` wraps the existing `GitHubClient`, so its request
  builders and tests stay as they are.
- **Checkout** gets its own protocol method (`checkoutCommand`) with the `.checkout` capability, when Handoff
  needs it for GitLab.

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

1. **`ForgeClient` protocol, GitHub only:** the protocol, `Forge` (`.github` only) with `ForgeCapabilities`,
   `RepoResult` moved into `TriageCore`, a `GitHubForge` adapter, AppStore routed through it. No behavior
   change; GitHub ids and `RepoRef` JSON unchanged (test).
2. **Core model:** `Forge.gitlab(host:)` on `RepoRef`, nested paths, host-aware ids for GitLab only, old
   `repos` JSON still decodes (test). No UI.
3. **GitLab client + mapping:** query, `toModel`, bot detection, system-note filtering, Classifier fixtures.
   `GitLabClient.mergeRequests()` returns one account-wide snapshot; the `ForgeClient` adapter comes with phase 4.
   Measure query complexity on the work account here. Capabilities `[]`.
4. **Wire into the app, read-only:** Settings section, Keychain token, refresh, sidebar row, GitLab links. MRs
   show and classify; no actions. Views hide actions by capability, and wording comes from the forge
   (`#`/`!`, "GitHub is still checking…", `gh pr view` in prompts). `/verify` + `/design-review`.
5. **Turn capabilities on, one PR each:** `.diff` + `.ciLogs` (AI summaries and fix prompts), `.checkout`
   (Handoff, extend `HandoffScriptIntegrationTests`), then `.approve`, `.merge`, `.close` (needs `api` scope,
   GitLab merge methods). **On hold:** broken down with implementation notes in [Still missing](#still-missing).

## Still missing

Phases 1–4 are in: GitLab MRs assigned to you or waiting on your review show in the inbox and the sidebar,
classified like GitHub PRs, with every action GitLab can't do yet hidden (`Forge.gitlab.capabilities == []`).
What's below is parked on purpose: none of it was needed day to day yet. Pick an item up when it is. Each is
one PR, and most start by adding a capability to `Forge.capabilities` for `.gitlab`, which un-hides the UI
that's already there for GitHub.

### Works with the current `read_api` token

1. **Diff in prompts** (`.diff`). "Explain & propose fix", "Copy prompt" and "Explain PR" get no code changes
   for a GitLab MR today. Implement `GitLabForge.diff` with REST
   `GET /api/v4/projects/:id/merge_requests/:iid/raw_diffs` (`:id` is the URL-encoded full path), and return nil
   on failure like GitHub. Then add `.diff` to GitLab's capabilities.
2. **CI job logs in fix prompts** (`.ciLogs`). `CheckInfo.checkRunID` already holds the numeric job id (parsed
   from `gid://gitlab/Ci::Build/<id>`). Implement `GitLabForge.ciLog` with REST
   `GET /api/v4/projects/:id/jobs/:job_id/trace`. The synthetic "Pipeline" check has no job id, so it gets no
   log: consider pointing it at the first failed job of a downstream pipeline instead. Ship together with 1.
3. **"Waiting on you" for reviews.** The list query knows whether an MR came from `assignedMergeRequests` or
   `reviewRequestedMergeRequests`, but `PullRequest` drops it. Carry a `role` (assignee / reviewer / both) on
   `PullRequest` (or on `GitLabClient`'s result), and let `Classifier.awaitingReview` say "Waiting for your
   review" when you're a reviewer who hasn't reviewed (`reviewState == UNREVIEWED` for the viewer). Needs a
   Classifier test; the item id must not change when only `role` changes.
4. **Fix in iTerm and Explain PR in iTerm** (`.checkout`).
   - `Handoff.originMatches` already works for GitLab remotes (`git@gitlab.com:group/sub/project.git`), and
     `findCheckout` looks for `<root>/<project name>`. Check both with a GitLab fixture.
   - Add "Set local checkout…" to the GitLab sidebar rows' context menu (`checkoutPaths` is keyed by
     `repo.id`, so it's host-aware already).
   - The handoff script's fork fallback runs `gh pr checkout`. Pass the forge's command in
     (`Forge.cli("checkout", n)`, i.e. `glab mr checkout n`) or drop the fallback for GitLab: there are no
     fork MRs, so `git fetch origin <branch>` always works.
   - Extend `HandoffScriptIntegrationTests`.
5. **Bot noise for GitLab-only bots.** `Classifier.noiseBots` is GitHub logins. The Terraform plan bot on
   GitLab posts "0 failure:" plans that the alarm words flag as findings. Either add GitLab bot names to the
   set (display names for access-token bots, see `GLUser.login`) or make the list a setting.

### Needs a token with the `api` scope

Settings should say which scope is missing when a write gets a 403, rather than a raw error.

6. **Approve** (`.approve`). `POST /api/v4/projects/:id/merge_requests/:iid/approve` with `sha` = head, so the
   approval is for the commit you saw (like GitHub's `commit_id`). `PullRequest.canBeApproved` already works from
   `approvedBy`; GitLab also allows approving your own MR if the project permits it, so check that rule.
7. **Merge** (`.merge`). `PUT /api/v4/projects/:id/merge_requests/:iid/merge` with `sha` (GitLab answers 409 if
   the head moved) and `squash`. Fetch the project's `mergeMethod` (merge / rebase_merge / ff) and
   `squashOption` in the detail query and map them onto `MergeMethod` (or a GitLab variant). `mergeBlocker`
   should read `detailedMergeStatus` (`DISCUSSIONS_NOT_RESOLVED`, `CI_MUST_PASS`, `NOT_APPROVED`, …), and
   "Merge when pipeline succeeds" is worth considering.
8. **Close** (`.close`). `PUT /api/v4/projects/:id/merge_requests/:iid` with `state_event=close`.

### Not GitLab, found on the way

- At the minimum window size (1000×600) the three columns overflow the window on `main` too: the sidebar's
  leading edge and the detail's trailing buttons clip. Found in #36's design review.

## Risks

- **Silent settings reset** if `RepoRef`'s Codable shape changes without a migration. Mitigation: a new key,
  and a decode test for old `repos` JSON.
- **Dismissals resetting** if GitHub item ids change. Mitigation: the phase 1 test.
- **Query complexity limits** forcing per-MR queries. Mitigation: measure early (spike in phase 2).
- **Interface drift:** a GitLab need that doesn't fit the protocol. Mitigation: phase 1 lands the protocol
  with GitHub alone, and the phase 3 spike checks it against real GitLab data before the app wiring.
- **Token scope/expiry:** gitlab.com PATs expire (max 1 year) and org policy may shorten it. Surface a 401
  as one clear "GitLab token expired" error, not per MR.
