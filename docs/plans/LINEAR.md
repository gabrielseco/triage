# Plan: Linear pings that need my answer

Status: planned, nothing built. Updated: 2026-09-29.

## Goal

Show a Linear item in Triage only when someone is waiting on me: they **@mention me** (in an issue or a
comment), or they **reply in a thread I'm part of**. Everything else Linear notifies about (assignments, status
changes, new comments on issues I only follow, reactions) stays out. An item leaves the inbox once I've answered,
not once I've read it.

## Decisions

1. **Read Linear's own notifications, don't rebuild them.** One GraphQL query, `notifications`, returns what
   Linear already worked out for me: who pinged me, on which issue, in which comment. Triage only filters it and
   decides when each one is answered. Scanning every issue's comments for `@me` would cost far more queries and
   miss what Linear already knows (such as thread subscriptions).
2. **Two kinds, from `IssueNotification.category`:**
   - `mentions` → **Mentioned**: someone @-ed me in an issue description or a comment.
   - `commentsAndReplies`, kept **only when it's a reply in a thread I've commented in** (the comment has a
     `parent`, and I wrote the parent or one of its replies) → **Thread reply**. A new top-level comment on an
     issue I merely follow is dropped.
3. **Open until answered, not until read.** An item stays until one of these happens:
   - I comment in that thread (or on the issue, for a description mention) after the ping
   - the thread is resolved (`Comment.resolvedAt`)
   - the issue is completed or canceled (`issue.state.type`)
   - I archive the notification in Linear (the query leaves archived ones out), or it's snoozed there
     (`snoozedUntilAt` in the future)
   - I dismiss or snooze it in Triage

   `readAt` is ignored. Reading a ping in Linear doesn't mean I've answered it.
4. **One item per thread.** Three replies in the same thread are one item that shows the latest reply. The id
   is `linear:<ISSUE-123>:<thread root comment id, or "issue">:<latest ping comment id>`, so a dismissed thread
   comes back only when there's a newer ping. This is the rule `AttentionItem.id` already follows for PRs.
5. **Its own model, not a fake PR.** `AttentionItem.pr` is a required `PullRequest`, used in 66 places. A Linear
   thread has no checks, reviews or merge state. A new `LinearPing` model and its own list, section and detail
   view keep the PR code untouched. The existing `dismissed` / `snoozed` sets are keyed by id string, so they
   work for pings unchanged. Revisit a shared "subject" type only if a third non-PR source ever shows up.
6. **Read-only.** A Linear personal API key with **Read** scope, in the Keychain, as the GitLab token is. Replying
   and marking read happen in Linear. Open (⌘O) goes straight to the comment.
7. **Deterministic.** The rules are plain code in `TriageCore`, with no AI deciding "is this a question?".
   An FYI mention stays until dismissed. Explain (⌘E) can come later as an on-demand "what do they need from
   me?"

## Fetching

`POST https://api.linear.app/graphql`, header `Authorization: <personal key>` (no `Bearer`), one call per
refresh, every 120 s alongside GitHub and GitLab:

```graphql
query Pings {
  viewer { id }
  notifications(first: 100) {            # archived are left out by default
    nodes {
      ... on IssueNotification {
        id type category createdAt snoozedUntilAt url
        actor { id displayName avatarUrl }
        issue { identifier title url state { type } team { key } }
        comment {
          id body url createdAt user { id }
          parent {
            id resolvedAt user { id }
            children(last: 20) { nodes { id createdAt user { id } } }
          }
          children(last: 20) { nodes { id createdAt user { id } } }
        }
      }
    }
  }
}
```

`IssueNotification.type` is a free string in the schema, not an enum. Phase 1 logs the real values from my
account before any rule depends on them, and classification keys off `category` wherever it can.

## Classifying (`TriageCore/LinearPings.swift`)

```
notifications
  → keep IssueNotification with category mentions, or commentsAndReplies in a thread I'm in
  → drop: issue completed/canceled, thread resolved, snoozed in Linear, actor is me
  → group by (issue, thread root)
  → drop the group if I commented in the thread after its latest ping
  → LinearPing { id, kind: .mentioned | .threadReply, issue, author, excerpt, url, pingedAt }
```

Tests (Swift Testing, fixtures made up rather than copied from the work workspace):

- A mention in a comment → one Mentioned item. My reply after it → gone.
- A reply in a thread I started → Thread reply. A top-level comment on a followed issue → nothing.
- Two replies in one thread → one item, the later one's text, the id changes with the second.
- Thread resolved, issue done, snoozed in Linear, my own comment → nothing.
- A mention in the issue description: answered by any comment of mine on the issue after it.

## App

| Area | Change |
| --- | --- |
| Settings | Linear section: "Show Linear pings" toggle and API key field (Keychain), like GitLab |
| `AppStore` | `linearPings: [LinearPing]`, fetched in `refreshOnce` next to the forges. The same hidden filter (`dismissed`, `snoozed`). An error shows as "Linear: …" with the others |
| Sidebar | A **Linear** section: *Mentioned N*, *Thread replies N* |
| List row | `ENG-123  Alice: "can you confirm the migration order?"`, the time since the ping, Linear's avatar |
| Detail | Issue title and state, the thread's last few comments with the ping highlighted, then **Open in Linear**, **Dismiss** and **Snooze** |
| Menu bar + digest | Pings count toward the badge and the "N new since 12:00" digest |

## Phases (one PR each)

1. **Core:** `LinearClient` (query, decode), `LinearPing`, the classification rules and tests. A throwaway
   debug run against my account records the real `type` strings, and only made-up fixtures get committed.
2. **App, read-only:** Settings, Keychain, refresh, sidebar section, row, detail, dismiss and snooze, menu bar
   and digest. `/verify` + `/design-review`, with screenshots of made-up data only.
3. **Later, if wanted:** Explain ("what do they need from me?"), a Read+Write key to mark read in Linear on
   Dismiss, and project or document mentions (`ProjectNotification` and others).

## Open questions

1. **Which threads count as "mine"?** The plan says threads I commented in. Should threads on issues
   **assigned to me** or **created by me** count too, even if I never commented?
2. **Description mentions:** I get pinged in an issue body and never comment, but I do the work. Should moving
   the issue to done be enough to clear it? (Planned: yes, completed or canceled clears it.)
3. **Should old pings be backfilled?** On first run, show every unanswered ping Linear still holds, or only
   pings from the last N days?

## Risks

- **`type` strings aren't documented as an enum.** That's why rules lean on `category` and phase 1 records the
  real values.
- **Long threads:** `children(last: 20)` could miss my reply in a longer thread. That would only make an item
  show that shouldn't, never hide one. Paginate if it ever happens.
- **Work data:** the Linear workspace is work data. Issue keys, titles and screenshots stay out of PRs, commits
  and comments (the same rule as GitLab).
