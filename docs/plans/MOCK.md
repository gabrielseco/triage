# Plan: run the whole app on mock data

Status: built in one PR. Written 2026-10-17.

## Goal

`TRIAGE_FIXTURE=<scenario.json>` runs the real app on data from one file. Nothing real is reached: no network, no
Keychain, no `gh`, no 1Password, no notification, no iTerm, no browser, and none of the installed app's settings. The
screen is the same on every run, so `/verify` and Workbench's `verify.sh` can photograph a state a goal names without
caring about GitHub, GitLab or tokens, and anyone can open the mock app to look at a state or try a change.

## Why

`scripts/verify.sh` copied the installed app's repo list and then had to work around what that dragged in: the GitLab
host (a Keychain dialog that blocked the first refresh), the live PR list (a screenshot of the owner's own pull
requests that cannot show a boundary between "mine" and "others'"), private titles in a public screenshot, and a
15 s wait for a network fetch. Each was patched on its own. A mock at the app's edges removes all of them at once.

## Decisions

1. **Mock at the edges, not in the views.** Every view and every rule (`Classifier`, ordering, digests) runs
   unchanged on mock data. Only what the app reads from outside is swapped.
2. **One scenario file drives everything**: the viewer on each forge, the watched repos, pull requests, Linear pings,
   GitLab mentions and the canned answers for Explain, the diff and a CI log. Times are written as hours ago, so
   "updated yesterday" stays true whenever it runs.
3. **The logic is in `TriageCore`**, pure and tested (`Mock/`): the scenario decoding, the fake forge, the fake Linear
   source and the fake explainer. The app target only chooses between real and mock, in one place per edge.
4. **Mock mode is inert, and says so.** Secrets are never read or written, notifications and the iTerm handoff are not
   sent, links do not open a browser, settings live in a throwaway defaults domain, and a request that still tries
   the network fails loudly. The window title is "Triage — mock data".
5. **Approve, merge and close work on the mock's own copy**, so a demo shows the flow, and nothing leaves the process.

## The edges

| Edge | Real | Mock |
| --- | --- | --- |
| GitHub, GitLab pull requests | `ForgeClient` (existing) | `MockForge` |
| GitLab mentions | `GitLabForge.mentions()` | `MentionsSource`, the mock forge |
| Linear pings | `LinearClient` | `LinearSource`, `MockLinear` |
| Explain (Anthropic) | `AnthropicClient` | `Explainer`, `MockExplainer` |
| Secrets (Keychain, 1Password, env, `gh`) | `GitHubAuth`, `GitLabAuth`, `LinearAuth`, `Keychain` | never called |
| Notifications | `Notifier` | no-op |
| Fix in iTerm, checkout search, folder picker | `AppStore+Handoff` | a status line only |
| Links | `openURL` | swallowed |
| Settings and state | `UserDefaults.standard` | `dev.rogal.triage.mock-state`, emptied at start |
| Network | `URLSession.shared` | a `URLProtocol` that fails every request |

## Running it

- `scripts/mock.sh [scenario]` builds a throwaway bundle with its own bundle id and opens it on a scenario
  (default `Mocks/default.json`). The installed app is never touched. `swift run Triage` with `TRIAGE_FIXTURE` set also
  works, without notifications.
- `scripts/verify-app.sh` is that build for something else to drive: `start [scenario]` prints its pid and window id and
  leaves it running, `list`, `press`, `shot` and `stop` take the pid and refuse any other process. `scripts/verify.sh` and
  the `/verify` skill under Workbench both use it.
- `Mocks/bot-findings.json` is the default scenario plus a bot finding on someone else's PR (#409, reviewed by the viewer),
  to see that the viewer's own findings come first and only they offer the fix actions.
- `scripts/verify.sh` always runs on a scenario (`VERIFY_FIXTURE`, default `Mocks/default.json`). It no longer copies
  settings, needs no GitLab handling and waits 3 s, not 15.

## The scenario's clock

"New PR" means opened after the app started watching the repo, and a first fetch starts that clock at "now", after
every PR in a scenario. So the scenario says when watching began (`watchingHoursAgo`, default 24) and the app starts
the clock there. GitLab mentions are polled 1 s in, not 30 s, because there is no token to read first. A scenario that
does not load makes the app end with the reason on stderr, which `open` would hide, so `mock.sh` and `verify.sh` run
`Triage --check-fixture` first and stop with the message.

## The default scenario

Ten pull requests across two GitHub repos and one GitLab project, written so the order shows: the viewer's own and
others', created in a different order than their numbers, one of every kind the sidebar has, plus Linear pings and
GitLab mentions. A test decodes it with the real models and classifies it, so it cannot drift from the app.

## Tests

- scenario decoding: every field, defaults, a missing file, a bad repo, an unknown forge;
- `MockForge`: viewer, one result per watched repo and per GitLab project, `approve`, `merge`, `close`;
- `MockLinear`, `MockExplainer`;
- the default scenario classifies into every attention kind and into both Linear ping kinds and a mention.

## Out of scope

- Mocking macOS itself (the login item, Screen Recording). Settings disables the login-item switch in mock mode.
- Recording real responses, or a mock server. The scenario is written by hand.
- A visual diff of screenshots.
