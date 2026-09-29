# Plan: Linear pings that need my answer

Status: phase 1 (client and rules in `TriageCore`) in review. Updated: 2026-09-29.

## Goal

The case this is for: I commented in a Linear thread, someone answered, and I only noticed 22 hours later.

Show a Linear item in Triage only when someone is waiting on me: they **@mention me** (in an issue or a
comment), or they **reply in a thread I'm part of**. Everything else Linear notifies about (assignments, status
changes, new comments on issues I only follow, reactions) stays out. A new ping **notifies me right away**, and
clicking the notification opens the comment in Linear, where I answer. Triage never replies for me. An item leaves
the inbox once I've answered, not once I've read it.

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
   is `linear:<ISSUE-123>:<thread root comment id, or "issue">:<latest ping comment id, or the notification id
   for a description mention>`, so a dismissed thread comes back only when there's a newer ping. This is the
   rule `AttentionItem.id` already follows for PRs.
5. **Its own model, not a fake PR.** `AttentionItem.pr` is a required `PullRequest`, used in 66 places. A Linear
   thread has no checks, reviews or merge state. A new `LinearPing` model and its own list, section and detail
   view keep the PR code untouched. The existing `dismissed` / `snoozed` sets are keyed by id string, so they
   can hold ping ids too, **but their pruning has to change**: `refreshOnce` keeps only ids in the live PR items
   (`AppStore.swift:284-288`), which would delete every Linear dismissal every 2 minutes. Each source prunes only
   its own ids (`linear:` prefix for Linear, everything else for PRs), and the selection check looks at both
   lists. Revisit a shared "subject" type only if a third non-PR source ever shows up.
6. **Read-only.** A Linear personal API key with **Read** scope, in the Keychain, as the GitLab token is. Replying
   and marking read happen in Linear. Open (⌘O) goes straight to the comment.
7. **A banner per ping, within about 30 s.** See [Notifications](#notifications). This is the main feature; the
   sidebar list is where the pings I haven't answered wait.
8. **Deterministic.** The rules are plain code in `TriageCore`, with no AI deciding "is this a question?".
   An FYI mention stays until dismissed. Explain (⌘E) can come later as an on-demand "what do they need from
   me?"

## Fetching

`POST https://api.linear.app/graphql`, header `Authorization: <personal key>` (no `Bearer`). Linear runs on
its **own 30 s loop**, not the 120 s PR refresh, because a ping should arrive fast. That's one small query, about
120 an hour, well under Linear's hourly limit for API keys (check the exact limit in phase 1). ⌘R refreshes it
too:

```graphql
query Pings($since: DateTimeOrDuration!, $types: [String!]!, $after: String) {
  notifications(
    first: 50, after: $after, orderBy: createdAt,
    filter: { createdAt: { gt: $since }, type: { in: $types } }
  ) {
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on IssueNotification {
        id type category createdAt snoozedUntilAt
        actor { name avatarUrl isMe }
        issue {
          identifier title url state { type }
          comments(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
        }
        comment {
          id body url createdAt resolvedAt
          children(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
          parent {
            id resolvedAt user { isMe }
            children(first: 20, filter: { user: { isMe: { eq: true } } }) { nodes { createdAt } }
          }
        }
      }
    }
  }
}
```

The query is in `LinearClient.notificationsQuery`. Instead of reading every comment in a thread and
comparing user ids, it asks only for **my** comments (`user: { isMe: { eq: true } }`). The rules only need to
know whether I answered after the ping, and it keeps each page small.

`IssueNotification.type` is a free string in the schema, not an enum, so the rules use only `category` (an
enum). The server-side filter uses `type`, because that's what `NotificationFilter` accepts:
`issueMention`, `issueCommentMention` and `issueNewComment` (`LinearClient.pingTypes`).

The client still follows `pageInfo` (up to 10 pages) so a busy month can't push a ping off the first page.

**Checked against my account (phase 1):**

- 308 notifications in 30 days, 258 of them "issue added to view". Without the type filter that was 7 pages per
  refresh. At one refresh every 30 s, that would use about 80% of Linear's hourly complexity budget (3,000,000;
  one page costs about 2,900). With the filter it's 24 notifications, one page, about 11%.
- Requests: 2,500 an hour per key; 120 an hour is fine.
- `-P30D` works as `$since`, and `orderBy: createdAt` returns newest first.
- Seen types: `issueCommentMention` (category `mentions`) and `issueNewComment` (category `commentsAndReplies`,
  both for thread replies and new top-level comments). `issueMention` wasn't seen; it's Linear's documented name
  for a mention in the description.
- The rules left 1 open ping out of 24: a reply in my thread. The others were answered, on closed issues, or
  not pings.

## Classifying (`TriageCore/LinearPings.swift`)

```
notifications
  → keep IssueNotification with category mentions, or commentsAndReplies in a thread I'm in
  → drop: older than 30 days, issue completed/canceled, thread resolved, snoozed in Linear, actor is me
  → group by (issue, thread root)
  → drop the group if I commented in the thread after its latest ping
  → LinearPing { id, kind: .mentioned | .threadReply, issue, author, excerpt, url, pingedAt }
```

Tests (Swift Testing, fixtures made up rather than copied from the work workspace):

- A mention in a comment → one Mentioned item. My reply after it → gone.
- A reply in a thread I started → Thread reply. A top-level comment on a followed issue → nothing.
- Two replies in one thread → one item, the later one's text, the id changes with the second.
- Thread resolved, issue done, snoozed in Linear, my own comment, a ping 31 days old → nothing.
- A mention in the issue description: answered by any comment of mine on the issue after it.

## Notifications

A macOS banner for each new ping, sent as soon as the 30 s poll sees it:

```
┌───────────────────────────────────────────────┐
│ Alice mentioned you · ENG-123                 │
│ "can you confirm the migration order before…" │
└───────────────────────────────────────────────┘
  Thread reply: "Bob replied in your thread · ENG-123"
```

- **New means an id not notified before.** Triage stores the ids of pings it has already notified, so a ping
  notifies once, even across restarts. A later reply in the same thread is a new id, so it notifies again.
- **No flood on first run or after being offline.** The first fetch after turning Linear on only records ids.
  Existing pings show in the list without a banner. After that, a fetch with more than 3 new pings sends one
  summary banner ("5 new Linear pings") instead of 5.
- **Click → the comment in Linear.** The notification carries the comment URL, and clicking it opens that URL
  in the browser (or the Linear app, if it handles `linear.app` links). Today `didReceive` always opens the digest,
  so it has to branch on a `kind` in `userInfo`. The summary banner opens Triage on the Linear section.
- **Grouped per issue** in Notification Center (`threadIdentifier = ISSUE-123`).
- **Sound on**, like the digest. Focus modes and macOS notification settings still apply. The digest's
  "weekdays only" doesn't, because a ping is time-sensitive.
- **Setting:** "Notify on every ping" under Settings → Linear, on by default.
- **Only in the bundled app.** `Notifier` needs a bundle id, like the digest (`scripts/bundle.sh`).

"Instant" here means within 30 s. Anything faster needs Linear webhooks, which need a public server to receive
them. That's out of scope for a local app.

### Hard to miss

A banner that slides away while I'm not looking is how a reply goes unseen for 22 hours. So a ping keeps asking
until I've answered it or dismissed it:

1. **Reminders.** If a ping is still open 1 hour after its banner, it notifies again ("Still waiting: Bob
   replied in your thread · ENG-123, 1 h ago"). Then again at 4 h, and after that once a day, at the first
   digest slot. Answering in Linear, or Dismiss or Snooze in Triage, stops the reminders. Snooze ends with one
   more reminder. The intervals are a setting (default 1 h, 4 h, daily).
2. **Always-visible menu bar mark.** While any ping is open, the menu bar icon shows a separate Linear count,
   apart from the PR count, and the menu lists the open pings first. It's a glance: no count, nothing waiting.
3. **Notifications that stay on screen.** macOS lets the user, not the app, choose Banners (slide away) or
   Alerts (stay until clicked) per app. When Linear is turned on, Settings → Linear says so and links to
   System Settings → Notifications → Triage. Time-sensitive notifications (which get through Focus) need an
   Apple entitlement that an ad-hoc signed app can't have, so that's out.

Reminder timing is pure logic too (`LinearPings.dueReminders(open:notifiedAt:now:schedule:)`), tested in
`TriageCore`. The notified-id store keeps the time of the last notification for each ping, so reminders
survive a restart.

The rule for which pings to notify is pure logic (`LinearPings.newPings(current:notified:isFirstRun:)`), in
`TriageCore` with tests. Only `Notifier.send` lives in the app.

## App

| Area | Change |
| --- | --- |
| Settings | Linear section: "Show Linear pings" toggle and API key field (Keychain), like GitLab |
| `AppStore` | `linearPings: [LinearPing]`, fetched in `refreshOnce` next to the forges. The same hidden filter (`dismissed`, `snoozed`). An error shows as "Linear: …" with the others |
| Sidebar | A **Linear** section: *Mentioned N*, *Thread replies N* |
| List row | `ENG-123  Alice: "can you confirm the migration order?"`, the time since the ping, Linear's avatar |
| Detail | Issue title and state, the thread's last few comments with the ping highlighted, then **Open in Linear**, **Dismiss** and **Snooze** |
| Menu bar | A separate Linear count next to the PR count (see [Hard to miss](#hard-to-miss)), and open pings first in the menu |
| Digest | Leaves pings out, since each one already notified |

## Phases (one PR each)

1. **Core:** `LinearClient` (query, decode), `LinearPing`, the classification rules and tests. A throwaway
   debug run against my account records the real `type` strings, and only made-up fixtures get committed.
2. **App, read-only:** Settings, Keychain, the 30 s loop, sidebar section, row, detail, dismiss and snooze, menu
   bar. `/verify` + `/design-review`, with screenshots of made-up data only.
3. **Notifications:** `newPings` + `dueReminders` + tests, a store of notified ids and times, banners, reminders,
   click → Linear, the summary banner, the menu bar Linear count, the Alerts hint in Settings. Verified by a real
   ping from a second account or a teammate.
4. **Later, if wanted:** Explain ("what do they need from me?"), a Read+Write key to mark read in Linear on
   Dismiss, and project or document mentions (`ProjectNotification` and others).

## Settled

1. **"My" threads are threads I commented in.** Issues assigned to me or created by me don't count on their own.
2. **A description mention is cleared** by a comment of mine on the issue, or by the issue being completed or
   canceled.
3. **Pings older than 30 days are dropped**, always, not only on first run. Long enough that nothing waiting on
   me is lost over a PTO, short enough that stale pings don't pile up. On first run, pings within the 30 days
   show in the list without banners.

## Risks

- **`type` strings aren't documented as an enum.** That's why rules lean on `category` and phase 1 records the
  real values.
- **Many replies of mine:** each thread fetches my first 20 comments. With more than 20, a newer one could be
  missed. That would only make an item show that shouldn't, never hide one. Paginate if it ever happens.
- **Work data:** the Linear workspace is work data. Issue keys, titles and screenshots stay out of PRs, commits
  and comments (the same rule as GitLab).
